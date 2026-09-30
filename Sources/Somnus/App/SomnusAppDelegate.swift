//  SomnusAppDelegate.swift
//  Somnus: app delegate.
//
//  Quitting somnus is a power-state event, not just an app event. `SleepDisabled`
//  is written to disk and outlives the process, while the battery policy lives
//  in the process. This delegate disarms a normal quit; the helper's heartbeat
//  watchdog covers crashes and force quits.

import AppKit
import Darwin
import SomnusKit

@MainActor
final class SomnusAppDelegate: NSObject, NSApplicationDelegate {

    /// Set when macOS itself is tearing the session down (logout, restart,
    /// shutdown). A modal dialog during that would stall the whole logout, so
    /// the quit guard steps aside: see `applicationShouldTerminate`.
    private var systemIsPoweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let command = SomnusTerminalCommand.current {
            // A one-shot invocation owns no power policy. It only performs the
            // app-bound ServiceManagement/notification operation, prints its
            // result to the calling terminal, and exits.
            setlinebuf(stdout)
            setlinebuf(stderr)
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                let status = await TerminalSetup.run(command)
                fflush(nil)
                Darwin.exit(status)
            }
            return
        }

        // LSUIElement is already YES in Somnus-Info.plist; this makes the policy
        // explicit for the case where the app is launched from a build
        // directory whose Info.plist has not been read as expected.
        NSApp.setActivationPolicy(.accessory)

        // Start the power engine even though nothing is on screen: the battery
        // safety net must be armed whether or not a window is ever opened.
        PowerEngineBridge.activate()
        AppStatusHeartbeat.shared.start()

        // Read the registration status. Nothing is registered automatically -
        // installing a root daemon is an explicit, user-initiated action in
        // Preferences, and re-registering behind the user's back would put a
        // System Settings approval prompt in their face at every login.
        let installation = HelperInstallation.shared
        installation.refresh()
        Task { await installation.checkHelperVersion() }

        // A crash or force-quit never reaches `applicationShouldTerminate`.
        // somnusd's heartbeat watchdog returns the machine to Normal Sleep;
        // meanwhile the menu can show the live unprotected state and recovery
        // command. Nothing is shown at launch and no permission prompt appears.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil)
    }

    @objc private func systemWillPowerOff() {
        systemIsPoweringOff = true
        // Another app can cancel the logout or restart, and nothing reports
        // that. Stand the guard back up after a minute so a later Command + Q
        // is still guarded; a teardown that is really happening sends its
        // quit event well within that, and `isSessionEndingQuit` covers the rest.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.systemIsPoweringOff = false
        }
    }

    /// `true` when the quit Apple Event in flight comes from loginwindow for a
    /// logout, restart or shutdown.
    private var isSessionEndingQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let sessionEnding: [OSType] = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog,
                                       kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }
        return sessionEnding.contains(reason)
    }

    /// `open -a Somnus` on an app that has no windows arrives here. This is the
    /// documented way into Preferences (and therefore into Uninstall), so it
    /// opens the window: but only in response to the user asking, never at
    /// launch.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        PreferencesWindowController.shared.show()
        return true
    }

    /// Closing the preferences window must not quit the app: the safety net
    /// runs headless.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - The quit guard

    /// Command + Q, the menu's Quit item and `NSApplication.terminate(_:)` all
    /// arrive here.
    ///
    /// The app does not offer an unprotected "quit anyway" path. A long job is
    /// exactly when the battery guardian must remain alive. Force Quit cannot
    /// be intercepted, so somnusd's heartbeat watchdog is the backstop there.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never block macOS's own logout/restart/shutdown with a modal.
        guard !systemIsPoweringOff, !isSessionEndingQuit else { return .terminateNow }

        Task { await self.decideQuit(sender) }
        return .terminateLater
    }

    private func decideQuit(_ sender: NSApplication) async {
        // `nil` (state unreadable) is treated as "on": warning about a Mac that
        // was going to sleep anyway is cheap, the reverse is not.
        guard await StayAwakeDisarm.currentlyOn() != false else {
            await finishTermination(sender, allowed: true)
            return
        }

        switch presentQuitWarning() {
        case .turnOffAndQuit:
            switch await StayAwakeDisarm.disarm() {
            case .notNeeded, .disarmed:
                await finishTermination(sender, allowed: true)
            case let .failed(reason):
                // The safe option just failed. Do not quit quietly on the back
                // of it: say so and let them choose again, knowing the truth.
                await finishTermination(sender, allowed: presentDisarmFailure(reason))
            }

        case .cancel:
            sender.reply(toApplicationShouldTerminate: false)
        }
    }

    private func finishTermination(_ sender: NSApplication, allowed: Bool) async {
        if allowed { await AppStatusHeartbeat.shared.stop() }
        sender.reply(toApplicationShouldTerminate: allowed)
    }

    private enum QuitChoice {
        case turnOffAndQuit
        case cancel
    }

    private func presentQuitWarning() -> QuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quitting leaves Stay Awake on"
        alert.informativeText = StayAwakeRecovery.strandedMessage("""
            somnus is about to quit while Stay Awake is on. The low-battery safety net only runs \
            while somnus runs, so once it quits nothing will turn Stay Awake off: not at \
            \(PowerEngine.shared.warnThreshold)%, not at \(PowerEngine.shared.actThreshold)%, not at 0%.
            """)

        // Safe option first: it is the default button and takes Return.
        alert.addButton(withTitle: "Turn Stay Awake Off and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}"     // Escape cancels

        // The app is an accessory, so without this the alert can open behind
        // whatever the user is looking at and the quit appears to hang.
        NSApp.activate()

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .turnOffAndQuit
        default:                       return .cancel
        }
    }

    /// Always returns `false`: the quit is refused, because there is no
    /// unprotected "quit anyway" path (see `applicationShouldTerminate`). Loops
    /// while the user keeps choosing Copy, so the command can be taken away.
    private func presentDisarmFailure(_ reason: String) -> Bool {
        while true {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Stay Awake could not be turned off"
            alert.informativeText = StayAwakeRecovery.strandedMessage("""
                somnus asked its helper to turn Stay Awake off and it did not take (\(reason)). \
                Stay Awake is still on, and if somnus quits now nothing will turn it off.
                """)

            alert.addButton(withTitle: StayAwakeRecovery.copyCommandButtonTitle)
            alert.addButton(withTitle: "Stay Open")
            alert.buttons.last?.keyEquivalent = "\u{1b}"

            NSApp.activate()

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                StayAwakeRecovery.copyCommand()
                continue                                 // ask again
            default:
                return false
            }
        }
    }
}
