//  SomnusApp.swift
//  Somnus: app entry point.
//
//  An LSUIElement SwiftUI app: no Dock icon, and no window at launch. The only
//  scene is a menu bar item, which creates a status item rather than a window;
//  preferences are an AppKit window opened on demand by
//  `PreferencesWindowController`.
//
//  Staying alive matters. This app is its own login item via
//  `SMAppService.mainApp`, and the battery safety net in Sources/Somnus/Power/
//  is inert whenever the app is not running: so registration is load-bearing
//  for the data-loss guarantee, not a convenience.

import AppKit
import AppIntents
import SwiftUI
import SomnusKit

@main
struct SomnusApp: App {

    @NSApplicationDelegateAdaptor(SomnusAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            if SomnusTerminalCommand.current == nil {
                MenuBarContent()
            }
        } label: {
            if SomnusTerminalCommand.current == nil {
                MenuBarLabel()
            } else {
                Image(systemName: "moon.zzz")
            }
        }
    }
}

/// The icon in the menu bar reflects the live Stay Awake value and changes to a
/// warning whenever Stay Awake is on but somnus has no way to turn it off.
private struct MenuBarLabel: View {

    private let installation = HelperInstallation.shared
    private let engine = PowerEngineBridge.engine

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(accessibilityTitle)
    }

    private var stranded: Bool {
        engine.facts?.sleepDisabled == true && installation.cannotChangeStayAwake
    }

    private var symbolName: String {
        if stranded { return "exclamationmark.triangle.fill" }
        guard let on = engine.facts?.sleepDisabled else { return "moon.zzz" }
        return on ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    private var accessibilityTitle: String {
        if stranded { return "somnus: Stay Awake is on and cannot be turned off" }
        guard let on = engine.facts?.sleepDisabled else { return "somnus: reading state" }
        return on ? "somnus: Stay Awake on" : "somnus: Stay Awake off"
    }
}

/// The menu bar is the everyday control surface. Every value comes from the
/// same observable engine/installation models as Preferences; toggling Stay
/// Awake still goes through somnusd and is not reflected until the confirmed
/// state-change event updates the engine.
private struct MenuBarContent: View {

    private let installation = HelperInstallation.shared
    private let engine = PowerEngineBridge.engine
    @State private var stayAwakeWriteInFlight = false
    @State private var lastWriteError: String?
    @State private var notificationPermission: NotificationPermission = .unknown
    @State private var controlConfigured: Bool?

    var body: some View {
        Group {
          Toggle(isOn: stayAwakeBinding) {
            Label(stayAwakeTitle,
                  systemImage: engine.facts?.sleepDisabled == true
                    ? "cup.and.saucer.fill"
                    : "cup.and.saucer")
        }
        .disabled(engine.facts == nil
                  || installation.cannotChangeStayAwake
                  || stayAwakeWriteInFlight
                  || cannotTurnOnSafely)

        Toggle(isOn: acAwareBinding) {
            Label("AC-aware Mode", systemImage: "powerplug")
        }

        Toggle(isOn: openAtLoginBinding) {
            Label("Open at Login", systemImage: "arrow.clockwise")
        }

        Divider()

        Menu {
            Text(batteryLine)
            Text("Warn at \(engine.warnThreshold)%")
            Text("Turn Stay Awake off at \(engine.actThreshold)%")
            Text("Restore an automatic shutoff at \(engine.actThreshold + SafetyNetPolicy.restoreMargin)%")
            Text("Battery warnings: \(notificationPermission.rawValue)")
            if PowerEngineBridge.health.safetyRestorePending {
                Text("Automatic restoration is pending")
            }

            Divider()

            Button("Configure Battery Safety…") {
                PreferencesWindowController.shared.show()
            }
        } label: {
            Label(batterySafetyTitle, systemImage: batterySafetySymbol)
        }

        Menu {
            Text(installation.state.summary)
            Text("Notifications: \(notificationPermission.rawValue)")
            Text(controlConfigured == true
                 ? "Control Center: configured"
                 : "Control Center: not detected")

            if installation.state.canInstall {
                Button("Finish Setup…") {
                    installation.install()
                    if installation.state.wantsSystemSettings {
                        installation.openSystemSettingsLoginItems()
                    }
                }
            }
            if installation.canRepair {
                Button("Repair Helper…") {
                    Task { await installation.repairRegistration() }
                }
            }

            Button("Open Login Items & Extensions…") {
                installation.openSystemSettingsLoginItems()
            }

            if notificationPermission == .notRequested {
                Button("Allow Battery Warnings…") {
                    Task {
                        notificationPermission = await PowerNotifier.shared
                            .requestPermissionForSetup()
                    }
                }
            } else if notificationPermission == .denied {
                Button("Open Notification Settings…") {
                    PowerNotifier.shared.openSystemSettings()
                }
            }

            Divider()

            Button("Settings & Diagnostics…") {
                PreferencesWindowController.shared.show()
            }
        } label: {
            Label(systemIntegrationTitle, systemImage: helperSymbol)
        }

        // The dangerous pairing: the Mac cannot sleep and somnus cannot fix it.
        // Reachable transiently after a crash or force-quit until the watchdog
        // acts, or persistently if the helper is unapproved or removed.
        if stranded {
            Divider()
            Text("Stay Awake is on and somnus cannot turn it off")
            Text("Your Mac will not sleep on a closed lid, on battery")
            Text("In Terminal: \(StayAwakeRecovery.command)")
            Button(StayAwakeRecovery.copyCommandButtonTitle) {
                StayAwakeRecovery.copyCommand()
            }
            Button("What to do about this…") {
                PreferencesWindowController.shared.show()
            }
            Divider()
        }

        if let writeError = lastWriteError {
            Text("Stay Awake change failed: \(writeError)")
        }

        Divider()

        Button("Settings & Diagnostics…") {
            PreferencesWindowController.shared.show()
        }
        .keyboardShortcut(",")

        Button("Refresh Status") {
            installation.refresh()
            Task {
                await installation.checkHelperVersion()
                await engine.refresh()
                await refreshSupplementaryStatus()
                AppStatusHeartbeat.shared.reloadControlCenterNow()
            }
        }

        Button("About Somnus") {
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }

        Divider()

          Button("Quit Somnus") {
              NSApplication.shared.terminate(nil)
          }
          .keyboardShortcut("q")
        }
        .task { await refreshSupplementaryStatus() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshSupplementaryStatus() }
            }
    }

    private var stayAwakeBinding: Binding<Bool> {
        Binding(
            get: { engine.facts?.sleepDisabled ?? false },
            set: { requested in
                guard !stayAwakeWriteInFlight else { return }
                stayAwakeWriteInFlight = true
                lastWriteError = nil
                Task { @MainActor in
                    defer { stayAwakeWriteInFlight = false }
                    do {
                        try await SomnusClient.shared.setStayAwake(requested)
                        await engine.refresh()
                    } catch {
                        lastWriteError = SomnusError.from(error).localizedDescription
                    }
                }
            })
    }

    private var acAwareBinding: Binding<Bool> {
        Binding(get: { engine.acAwareModeEnabled },
                set: { engine.acAwareModeEnabled = $0 })
    }

    private var openAtLoginBinding: Binding<Bool> {
        Binding(get: { installation.loginItem.isRequested },
                set: { installation.setLoginItemEnabled($0) })
    }

    private var stayAwakeTitle: String {
        stayAwakeWriteInFlight ? "Changing Stay Awake…" : "Stay Awake"
    }

    /// Never prevent the safe direction: an unhealthy guardian blocks ON but
    /// the same toggle must remain able to turn an existing state OFF.
    private var cannotTurnOnSafely: Bool {
        engine.facts?.sleepDisabled != true
            && (!PowerEngineBridge.health.safetyNetArmed
                || !PowerEngineBridge.health.idleAssertionsHealthy)
    }

    private var batteryLine: String {
        guard let facts = engine.facts else { return "Reading battery…" }
        if facts.isCharging { return "Battery \(facts.batteryPercent)% · Charging" }
        return facts.isOnAC
            ? "Battery \(facts.batteryPercent)% · Power adapter"
            : "Battery \(facts.batteryPercent)% · Unplugged"
    }

    private var batterySafetyTitle: String {
        let health = PowerEngineBridge.health
        if !health.isMonitoring { return "Battery Safety Off" }
        if !health.safetyNetArmed { return "Battery Safety Not Armed" }
        if health.monitoringDegradedReason != nil { return "Battery Safety Degraded" }
        return "Battery Safety Armed"
    }

    private var batterySafetySymbol: String {
        let health = PowerEngineBridge.health
        if !health.isMonitoring || !health.safetyNetArmed {
            return "exclamationmark.octagon.fill"
        }
        if health.monitoringDegradedReason != nil {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.shield.fill"
    }

    private var helperSymbol: String {
        systemIntegrationReady
            ? "checkmark.seal.fill"
            : "exclamationmark.triangle.fill"
    }

    private var systemIntegrationReady: Bool {
        installation.state.isOperational
            && !installation.helperUnreachable
            && !installation.hasVersionSkew
            && installation.loginItem.isOperational
            && notificationPermission.canDeliverWarnings
            && controlConfigured == true
    }

    private var systemIntegrationTitle: String {
        systemIntegrationReady ? "System Integration Ready" : "System Integration Needs Attention"
    }

    private func refreshSupplementaryStatus() async {
        installation.refresh()
        await installation.checkHelperVersion()
        notificationPermission = await PowerNotifier.shared.permission()
        controlConfigured = await TerminalSetup.isControlConfigured()
    }

    private var stranded: Bool {
        engine.facts?.sleepDisabled == true && installation.cannotChangeStayAwake
    }
}
