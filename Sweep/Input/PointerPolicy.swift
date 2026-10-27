import Foundation

/// What happens to pointer events (moves, clicks, scrolls, gestures) during a session.
///
/// macOS delivers trackpad and mouse input as the same CGEvents with no public source
/// field, so "only one of them" policies rely on `PointerAttribution`, an approximation.
nonisolated enum PointerPolicy: Equatable, Sendable {
    case passAll
    case blockAll
    /// Block everything except events that coincide with HID activity from an external mouse.
    case allowOnlyExternalMice
    /// Block only events that coincide with HID activity from an external mouse.
    case blockOnlyExternalMice

    static func make(blockTrackpad: Bool, blockMouse: Bool, hasExternalMouse: Bool, hasTrackpad: Bool) -> PointerPolicy {
        switch (blockTrackpad, blockMouse) {
        case (false, false):
            .passAll
        case (true, true):
            .blockAll
        case (true, false):
            hasExternalMouse ? .allowOnlyExternalMice : .blockAll
        case (false, true):
            switch (hasExternalMouse, hasTrackpad) {
            case (false, _): .passAll
            case (true, false): .blockAll
            case (true, true): .blockOnlyExternalMice
            }
        }
    }

    var needsMouseAttribution: Bool {
        self == .allowOnlyExternalMice || self == .blockOnlyExternalMice
    }

    /// Whether some pointing device still works, so on-screen controls can be clicked.
    var leavesPointerUsable: Bool {
        self != .blockAll
    }
}

/// Decides whether a pointer event came from an external mouse by correlating it with the
/// HID reports that mouse produced (observed through IOHIDManager).
nonisolated enum PointerAttribution {
    enum Verdict: Equatable, Sendable {
        case externalMouse, other, undetermined
    }

    /// A mouse in motion reports every 1–8 ms; anything within this window counts as its activity.
    static let recentActivityWindow: TimeInterval = 0.030
    /// How long a discrete event (click, wheel notch) may wait for its HID report to arrive.
    static let graceWindow: TimeInterval = 0.015

    static func verdict(
        eventTime: TimeInterval,
        lastMouseActivity: TimeInterval?,
        now: TimeInterval,
        allowsGrace: Bool
    ) -> Verdict {
        if let last = lastMouseActivity, last >= eventTime - recentActivityWindow {
            return .externalMouse
        }
        if allowsGrace, now - eventTime < graceWindow {
            return .undetermined
        }
        return .other
    }

    static func shouldBlock(policy: PointerPolicy, isGesture: Bool, verdict: Verdict) -> Bool {
        switch policy {
        case .passAll: false
        case .blockAll: true
        // Gestures (pinch, swipe, rotate, force click) only come from multi-touch surfaces.
        case .allowOnlyExternalMice: isGesture || verdict != .externalMouse
        case .blockOnlyExternalMice: !isGesture && verdict == .externalMouse
        }
    }
}
