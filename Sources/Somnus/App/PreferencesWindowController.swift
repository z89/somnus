//  PreferencesWindowController.swift
//  Somnus: preferences window controller.
//
//  An AppKit window hosting the SwiftUI preferences, rather than a SwiftUI
//  `Settings`/`Window` scene, for one reason: the app must open no window at
//  launch, and this way opening is an explicit call and nothing else. The window
//  is built the first time it is asked for and kept afterwards.

import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {

    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        // The app is an accessory (no Dock icon), so it has to ask for
        // activation or the window opens behind whatever the user is doing.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        // Opening the window is itself the refresh event. Swift Observation
        // then keeps live engine changes flowing without a UI polling loop.
        HelperInstallation.shared.refresh()
        Task { @MainActor in
            await HelperInstallation.shared.checkHelperVersion()
            await PowerEngineBridge.engine.refresh()
        }
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(
            rootView: PreferencesView(engine: PowerEngineBridge.engine))

        let window = NSWindow(contentViewController: controller)
        window.title = "somnus"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SomnusPreferences")
        return window
    }
}
