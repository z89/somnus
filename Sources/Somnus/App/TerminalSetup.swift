//  TerminalSetup.swift
//  Somnus: one-shot setup, diagnostics and service removal from Terminal.
//
//  These commands run through Somnus.app's executable rather than through the
//  standalone CLI. SMAppService registers helpers relative to the containing
//  app bundle, so the app remains the one owner of installation state.

import AppKit
import Darwin
import Foundation
import SomnusKit
import WidgetKit

enum SomnusTerminalCommand: Equatable {
    case setup(repairIfNeeded: Bool)
    case doctor
    case uninstallServices

    static let current: SomnusTerminalCommand? = {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--somnus-setup") {
            return .setup(repairIfNeeded: arguments.contains("--repair-helper"))
        }
        if arguments.contains("--somnus-doctor") { return .doctor }
        if arguments.contains("--somnus-uninstall-services") { return .uninstallServices }
        return nil
    }()
}

@MainActor
enum TerminalSetup {
    private static let helperApprovalTimeout: Duration = .seconds(600)

    static func run(_ command: SomnusTerminalCommand) async -> Int32 {
        switch command {
        case let .setup(repairIfNeeded):
            return await setup(repairIfNeeded: repairIfNeeded)
        case .doctor:
            return await doctor()
        case .uninstallServices:
            return await uninstallServices()
        }
    }

    private static func setup(repairIfNeeded: Bool) async -> Int32 {
        guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Somnus.app" else {
            error("Somnus must be installed at /Applications/Somnus.app before setup.")
            return 1
        }

        heading("1/3  System helper and login item")
        let installation = HelperInstallation.shared
        installation.refresh()
        installation.install()

        if repairIfNeeded {
            note("Refreshing the helper registration for the installed app update.")
            guard await installation.repairRegistration() else {
                if let message = installation.lastMessage { error(message) }
                return 1
            }
            guard await waitForOperationalHelper(installation) else { return 1 }
        } else {
            guard await waitForOperationalHelper(installation) else { return 1 }
        }

        await installation.checkHelperVersion()
        if !repairIfNeeded && (installation.hasVersionSkew || installation.helperUnreachable) {
            error("The installed helper is not the same build as Somnus.app.")
            note("Run `somnus setup --repair` to re-register it safely.")
            return 1
        }

        guard installation.reportedHelperVersion == installation.expectedHelperVersion else {
            error("The helper answered, but its version could not be verified.")
            return 1
        }
        success("Helper approved and responding: \(installation.expectedHelperVersion)")

        guard await waitForOperationalLoginItem(installation) else { return 1 }
        success("Open at login is enabled.")

        heading("2/3  Battery warning notifications")
        let before = await PowerNotifier.shared.permission()
        if before == .notRequested {
            note("macOS will ask whether Somnus may show its low-battery warnings.")
            NSApp.activate()
        }
        let permission = await PowerNotifier.shared.requestPermissionForSetup()
        if permission.canDeliverWarnings {
            success("Notifications: \(permission.rawValue)")
        } else if permission == .denied {
            warning("Notifications were denied. The safety cutoff still works, but its warnings will not be visible.")
            if PowerNotifier.shared.openSystemSettings() {
                note("Opened System Settings > Notifications > Somnus so you can allow them.")
            } else {
                note("Open System Settings > Notifications > Somnus to allow them.")
            }
        } else {
            warning("Notification permission could not be verified (\(permission.rawValue)).")
        }

        heading("3/3  Control Center")
        var controlInstalled = await isControlConfigured()
        if controlInstalled == true {
            success("Stay Awake is already in Control Center.")
        } else if controlInstalled == false {
            note("Open Control Center, choose Edit Controls, then add Somnus > Stay Awake.")
            if isatty(STDIN_FILENO) == 1 {
                let response = await readLineAsync(
                    "Press Return after adding it, or type s to skip: ")
                if response?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "s" {
                    controlInstalled = await isControlConfigured()
                }
            }
            if controlInstalled == true {
                success("Control Center: configured")
            } else {
                warning("Control Center tile not detected. The menu bar and CLI still work.")
            }
        } else {
            warning("macOS did not return the current Control Center configuration.")
        }

        print("")
        success("Somnus setup is complete.")
        return 0
    }

    private static func waitForOperationalHelper(_ installation: HelperInstallation) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: helperApprovalTimeout)
        var openedSettings = false
        var unhealthyAttempts = 0

        while clock.now < deadline {
            installation.refresh()

            switch installation.state {
            case .installed:
                if await SomnusClient.shared.helperIsHealthy() { return true }
                unhealthyAttempts += 1
                if unhealthyAttempts >= 10 {
                    error("macOS says the helper is enabled, but it is not answering this app.")
                    note("Run `somnus setup --repair` to replace its registration safely.")
                    return false
                }

            case .awaitingApproval, .declinedByUser, .disabledInSystemSettings:
                unhealthyAttempts = 0
                if !openedSettings {
                    note("An administrator must enable Somnus in Login Items & Extensions.")
                    note("Opening the exact System Settings page now; this terminal will wait.")
                    installation.openSystemSettingsLoginItems()
                    openedSettings = true
                }

            case .notInstalled, .bundleBroken, .failed, .unrecognisedStatus:
                error(installation.state.guidance)
                return false

            case .unknown:
                unhealthyAttempts = 0
                break
            }

            try? await Task.sleep(for: .seconds(1))
        }

        error("Timed out after ten minutes waiting for helper approval.")
        note("Run `somnus setup --repair` when you are ready to continue.")
        return false
    }

    private static func waitForOperationalLoginItem(_ installation: HelperInstallation) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: helperApprovalTimeout)
        var openedSettings = false

        while clock.now < deadline {
            installation.refresh()
            switch installation.loginItem {
            case .enabled:
                return true
            case .awaitingApproval:
                if !openedSettings {
                    note("macOS must also allow Somnus to open at login so battery protection returns after a restart.")
                    installation.openSystemSettingsLoginItems()
                    openedSettings = true
                }
            case .disabled:
                error("Open at login was not enabled. Run `somnus setup` to try again.")
                return false
            case let .problem(message):
                error(message)
                return false
            case .unknown:
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }

        error("Timed out after ten minutes waiting for Open at Login approval.")
        note("Run `somnus setup` when you are ready to continue.")
        return false
    }

    private static func doctor() async -> Int32 {
        heading("Somnus doctor")
        var healthy = true
        let installation = HelperInstallation.shared
        installation.refresh()
        await installation.checkHelperVersion()

        let appInApplications = Bundle.main.bundleURL.standardizedFileURL.path
            == "/Applications/Somnus.app"
        report("App", appInApplications ? "installed in /Applications" : "running outside /Applications",
               okay: appInApplications)
        healthy = healthy && appInApplications

        let helperOkay = installation.state.isOperational
            && !installation.helperUnreachable
            && !installation.hasVersionSkew
        report("Helper", helperOkay ? "approved, current and responding" : installation.state.summary,
               okay: helperOkay)
        healthy = healthy && helperOkay

        report("Open at login", installation.loginItem.isOperational ? "enabled" : installation.loginItem.detail,
               okay: installation.loginItem.isOperational)
        healthy = healthy && installation.loginItem.isOperational

        let notifications = await PowerNotifier.shared.permission()
        report("Notifications", notifications.rawValue, okay: notifications.canDeliverWarnings)

        let control = await isControlConfigured()
        report("Control Center", control == true ? "configured" : "not configured",
               okay: control == true)

        do {
            let status = try await SomnusClient.shared.controlStatus()
            report("Menu-bar app", status.appRunning ? "running" : "not running",
                   okay: status.appRunning)
            report("Battery safety", status.safetyNetArmed ? "armed" : "not armed",
                   okay: status.safetyNetArmed)
            healthy = healthy && status.appRunning && status.safetyNetArmed
            report("Stay Awake", status.stayAwakeOn ? "on" : "off", okay: true)
            report("AC-aware mode", status.acAwareModeEnabled ? "on" : "off", okay: true)
        } catch {
            report("Live status", SomnusError.from(error).localizedDescription, okay: false)
            healthy = false
        }

        print("")
        if healthy {
            success("Core installation and battery protection are healthy.")
            return 0
        }
        error("Somnus needs attention. Run `somnus setup --repair` and then `somnus doctor` again.")
        return 1
    }

    private static func uninstallServices() async -> Int32 {
        heading("Removing Somnus services")
        let installation = HelperInstallation.shared
        installation.refresh()
        let safelyRemoved = await installation.uninstall()
        installation.refresh()

        if let message = installation.lastMessage { print(message) }
        guard safelyRemoved,
              installation.state == .notInstalled,
              installation.loginItem == .disabled else {
            error("Somnus services could not be removed safely. The app has been left in place.")
            return 1
        }
        success("Stay Awake is off and Somnus services are unregistered.")
        return 0
    }

    static func isControlConfigured() async -> Bool? {
        do {
            return try await ControlCenter.shared.currentControls()
                .contains { $0.kind == SomnusConstants.controlKind }
        } catch {
            return nil
        }
    }

    private static func readLineAsync(_ prompt: String) async -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return await Task.detached(priority: .userInitiated) { readLine() }.value
    }

    private static func heading(_ text: String) { print("\n\(text)") }
    private static func note(_ text: String) { print("  \(text)") }
    private static func success(_ text: String) { print("  [ok] \(text)") }
    private static func warning(_ text: String) { print("  [warning] \(text)") }
    private static func error(_ text: String) { fputs("  [error] \(text)\n", stderr) }

    private static func report(_ name: String, _ value: String, okay: Bool) {
        print("  \(okay ? "[ok]" : "[warning]") \(name): \(value)")
    }
}
