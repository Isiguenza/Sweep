//
//  SweepApp.swift
//  Sweep
//
//  Created by Iñaki Siguenza on 27/10/26.
//

import AppKit
import SwiftUI

/// Driven from AppKit directly: Sweep switches between a menu bar agent and a regular
/// app at runtime, which SwiftUI scenes do not model.
@main
enum SweepMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var settingsWindow: NSWindow?
    private var mainWindow: NSWindow?

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        NSApp.mainMenu = makeMainMenu()
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        controller.onShowWindow = { [weak self] in self?.showMainWindow() }
        controller.launch()
        // Opening the app (first time, or again after ⌘Q) shows the window; a login launch
        // in menu bar mode stays quiet.
        if !(launchedAsLoginItem && controller.preferences.showInMenuBar) {
            showMainWindow()
        }
    }

    /// Opening Sweep again from Finder, Launchpad or the Dock while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !controller.session.isRunning { showMainWindow() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    private func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainWindowView(controller: controller))
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Sweep"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // Size to the content now so centring uses the real size.
            hosting.view.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.view.fittingSize)
            mainWindow = window
            controller.mainWindow = window
        }
        if let window = mainWindow, !window.isVisible {
            center(window)
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Exactly in the middle of the screen in use (`NSWindow.center()` sits higher).
    private func center(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded()))
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.terminate()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller))
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "Sweep Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Invisible for an agent app, but provides the standard key equivalents (⌘W, ⌘Q, editing).
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sweep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }
}
