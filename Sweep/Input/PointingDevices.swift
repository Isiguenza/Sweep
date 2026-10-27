import Foundation
import IOKit.hid
import Observation

nonisolated enum PointingDeviceKind: Sendable {
    case trackpad, mouse
}

nonisolated struct PointingDevice: Identifiable, Hashable, Sendable {
    let id: UInt64
    let name: String
    let kind: PointingDeviceKind
}

nonisolated enum PointingDeviceClassifier {
    /// Pointer-like HID interfaces: mouse, pointer, and digitizer touch pad.
    static let matching: [[String: Int]] = [
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer, kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchPad],
    ]

    static func classify(_ device: IOHIDDevice) -> PointingDevice? {
        let page = intProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = intProperty(device, kIOHIDPrimaryUsageKey)
        let isTouchPad = page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_TouchPad
        let isPointer = page == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer)
        guard isTouchPad || isPointer else { return nil }

        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let builtIn = intProperty(device, kIOHIDBuiltInKey) == 1
        // The built-in trackpad reports through a "Built-In" HID interface; external Magic
        // Trackpads identify themselves by name or by the digitizer touch-pad usage.
        let isTrackpad = isTouchPad || builtIn || name.localizedCaseInsensitiveContains("trackpad")

        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        let displayName = isTrackpad && builtIn ? "Built-in Trackpad" : (name.isEmpty ? "Mouse" : name)
        return PointingDevice(id: registryID, name: displayName, kind: isTrackpad ? .trackpad : .mouse)
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        let value = IOHIDDeviceGetProperty(device, key as CFString)
        if let number = value as? Int { return number }
        if let flag = value as? Bool { return flag ? 1 : 0 }
        return nil
    }
}

/// Live list of connected pointing devices, for the UI and for choosing a pointer policy.
/// Enumeration does not need any permission.
@Observable
final class PointingDeviceCatalog {
    private(set) var devices: [PointingDevice] = []

    @ObservationIgnored private var manager: IOHIDManager?

    var trackpads: [PointingDevice] { unique(.trackpad) }
    var mice: [PointingDevice] { unique(.mouse) }

    func startObserving() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, PointingDeviceClassifier.matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, catalogDeviceChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, catalogDeviceChanged, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        refresh()
    }

    fileprivate func refresh() {
        guard let manager else { return }
        let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        devices = set.compactMap(PointingDeviceClassifier.classify).sorted { $0.name < $1.name }
    }

    private func unique(_ kind: PointingDeviceKind) -> [PointingDevice] {
        var seen = Set<String>()
        return devices.filter { $0.kind == kind && seen.insert($0.name).inserted }
    }
}

nonisolated private func catalogDeviceChanged(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context else { return }
    nonisolated(unsafe) let catalog = context
    // Removal callbacks fire before the device leaves the manager's set; refresh afterwards.
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            Unmanaged<PointingDeviceCatalog>.fromOpaque(catalog).takeUnretainedValue().refresh()
        }
    }
}

nonisolated enum MouseMonitorError: Error, Equatable {
    case notPermitted, unavailable
}

protocol MouseActivityMonitoring: AnyObject {
    func start() throws(MouseMonitorError)
    func stop()
}

/// Reads raw HID reports from external mice on a background thread and timestamps them,
/// so the event tap can tell mouse input from trackpad input. Needs Input Monitoring.
final class HIDMouseActivityMonitor: MouseActivityMonitoring {
    private let log: MouseActivityLog
    private var worker: HIDWorker?

    init(log: MouseActivityLog) {
        self.log = log
    }

    func start() throws(MouseMonitorError) {
        stop()
        let worker = HIDWorker(log: log)
        switch worker.result {
        case kIOReturnSuccess:
            self.worker = worker
        case kIOReturnNotPermitted:
            worker.stop()
            throw .notPermitted
        default:
            worker.stop()
            throw .unavailable
        }
    }

    func stop() {
        worker?.stop()
        worker = nil
        log.reset()
    }
}

nonisolated private final class HIDWorker: @unchecked Sendable {
    let log: MouseActivityLog
    private(set) var result: IOReturn = kIOReturnError
    /// Devices classified as external mice. Only touched on the worker thread.
    var mice = Set<UnsafeMutableRawPointer>()
    private var runLoop: CFRunLoop?

    init(log: MouseActivityLog) {
        self.log = log
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatchingMultiple(manager, PointingDeviceClassifier.matching as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, workerDeviceAdded, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, workerDeviceRemoved, context)
            IOHIDManagerRegisterInputValueCallback(manager, workerInputValue, context)
            let loop: CFRunLoop = CFRunLoopGetCurrent()
            runLoop = loop
            IOHIDManagerScheduleWithRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            ready.signal()
            if result == kIOReturnSuccess { CFRunLoopRun() }
            IOHIDManagerUnscheduleFromRunLoop(manager, loop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        thread.name = "Sweep.HID"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func stop() {
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

nonisolated private func workerDeviceAdded(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context, PointingDeviceClassifier.classify(device)?.kind == .mouse else { return }
    Unmanaged<HIDWorker>.fromOpaque(context).takeUnretainedValue().mice.insert(Unmanaged.passUnretained(device).toOpaque())
}

nonisolated private func workerDeviceRemoved(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<HIDWorker>.fromOpaque(context).takeUnretainedValue().mice.remove(Unmanaged.passUnretained(device).toOpaque())
}

nonisolated private func workerInputValue(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context else { return }
    let worker = Unmanaged<HIDWorker>.fromOpaque(context).takeUnretainedValue()
    let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
    if worker.mice.contains(Unmanaged.passUnretained(device).toOpaque()) {
        worker.log.record(MonotonicTime.now())
    }
}
