//  PreferencesView.swift
//  Somnus: preferences UI.
//
//  Renders and binds; it does not monitor. Every power value on screen comes
//  through `PowerEngineObserving` (SomnusKit's shared seam) and
//  every installation value through `HelperInstallation`. There is no IOKit, no
//  pmset, and no power logic in this file, and nothing here keeps its own copy
//  of the Stay Awake state.

import AppKit
import SwiftUI
import SomnusKit

struct PreferencesView: View {

    let engine: any PowerEngineObserving

    private let installation = HelperInstallation.shared

    @State private var notificationPermission: NotificationPermission = .unknown
    @State private var controlConfigured: Bool?

    var body: some View {
        let health = PowerEngineBridge.health
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SafetyNetSection(engine: engine,
                                 health: health,
                                 installation: installation)
                PowerFactsSection(facts: engine.facts)
                AssertionsSection(assertions: engine.assertions)
                SystemIntegrationSection(
                    installation: installation,
                    stayAwakeOn: engine.facts?.sleepDisabled,
                    notificationPermission: $notificationPermission,
                    controlConfigured: $controlConfigured)
                FooterView(installation: installation)
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 660)
        .task { await refreshOnce() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshOnce() }
            }
    }

    private func refreshOnce() async {
        await engine.refresh()
        installation.refresh()
        await installation.checkHelperVersion()
        notificationPermission = await PowerNotifier.shared.permission()
        controlConfigured = await TerminalSetup.isControlConfigured()
    }
}

// MARK: - System integration

private struct SystemIntegrationSection: View {

    let installation: HelperInstallation
    let stayAwakeOn: Bool?
    @Binding var notificationPermission: NotificationPermission
    @Binding var controlConfigured: Bool?
    @State private var advancedExpanded = false

    private var stranded: Bool {
        stayAwakeOn == true && installation.cannotChangeStayAwake
    }

    private var helperReady: Bool {
        installation.state.isOperational
            && !installation.hasVersionSkew
            && !installation.helperUnreachable
    }

    var body: some View {
        SectionCard(title: "System integration") {
            if stranded {
                RecoveryAdvisory(text: StayAwakeRecovery.strandedMessage("""
                    Stay Awake is on and somnus cannot turn it off, because the helper is not \
                    installed, not approved, or not answering. Your Mac will not sleep when you \
                    close the lid, even on battery and unattended, and the low-battery \
                    safety net cannot save it either, because it needs the same helper.
                    """))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: helperReady ? "checkmark.seal.fill" : installation.state.symbolName)
                    .foregroundStyle(helperReady ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(helperReady ? "Helper approved and responding" : installation.state.title)
                    .font(.headline)
            }

            if !helperReady {
                Text(installation.state.guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = installation.lastMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if installation.hasVersionSkew {
                Advisory(text: """
                    The running helper reports version \
                    \(installation.reportedHelperVersion ?? "unknown") but this copy of somnus is \
                    \(installation.expectedHelperVersion). After an app update the helper has to be \
                    registered again or macOS may not launch it. It still works in the meantime.
                    """)
            }

            if installation.helperUnreachable {
                Advisory(text: """
                    macOS reports the helper as approved, but it is not answering. That is what a \
                    registration left over from an older copy of somnus looks like: Repair \
                    unregisters and registers it again.
                    """)
            }

            if !helperReady {
                HStack {
                    if installation.state.canInstall {
                        Button("Finish Setup…") {
                            installation.install()
                            if installation.state.wantsSystemSettings {
                                installation.openSystemSettingsLoginItems()
                            }
                        }
                            .buttonStyle(.borderedProminent)
                    }
                    if installation.state.wantsSystemSettings {
                        Button("Open Login Items & Extensions") {
                            installation.openSystemSettingsLoginItems()
                        }
                    }
                    if installation.canRepair {
                        Button("Repair") {
                            Task { await installation.repairRegistration() }
                        }
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }

            Divider()

            FactRow(name: "Battery warnings", value: notificationPermission.rawValue.capitalized)
            if !notificationPermission.canDeliverWarnings {
                if notificationPermission == .notRequested {
                    Button("Allow Battery Warnings…") {
                        Task { notificationPermission = await PowerNotifier.shared.requestPermissionForSetup() }
                    }
                } else if notificationPermission == .denied {
                    Button("Open Notification Settings…") {
                        PowerNotifier.shared.openSystemSettings()
                    }
                }
            }

            FactRow(name: "Control Center",
                    value: controlConfigured.map { $0 ? "Configured" : "Not added" } ?? "Unknown")
            if controlConfigured == false {
                Text("Open Control Center, choose Edit Controls, then add Somnus > Stay Awake.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Check Again") {
                    Task { controlConfigured = await TerminalSetup.isControlConfigured() }
                }
            }

            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    FactRow(name: "App/helper build", value: installation.expectedHelperVersion)
                    HStack {
                        Button("Open Login Items & Extensions…") {
                            installation.openSystemSettingsLoginItems()
                        }
                        if installation.canRepair {
                            Button("Repair Helper…") {
                                Task { await installation.repairRegistration() }
                            }
                        }
                        Spacer()
                        if installation.state.canUninstall {
                            Button("Uninstall Services…") {
                                Task { await installation.uninstall() }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Safety net

private struct SafetyNetSection: View {

    let engine: any PowerEngineObserving
    let health: PowerEngineHealth
    let installation: HelperInstallation

    var body: some View {
        SectionCard(title: "Battery safety net") {
            HStack(spacing: 8) {
                Image(systemName: monitoringSymbol)
                    .foregroundStyle(monitoringColour)
                    .accessibilityHidden(true)
                Text(monitoringTitle)
                    .font(.headline)
                Spacer()
                if let lastEvaluation = health.lastEvaluation {
                    Text("Checked \(lastEvaluation, style: .relative)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Starting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let reason = health.monitoringDegradedReason { Advisory(text: reason) }
            if !health.safetyNetArmed, let reason = health.safetyNetDisarmedReason {
                Advisory(text: reason)
            }
            if !health.idleAssertionsHealthy {
                Advisory(text: "Somnus could not hold the display awake. Normal Sleep will be restored automatically unless the display assertion recovers.")
            }
            if health.safetyRestorePending {
                Advisory(text: """
                    somnus turned Stay Awake off at low battery. It will restore the earlier ON \
                    state at \(engine.actThreshold + SafetyNetPolicy.restoreMargin)% battery, whether charging or unplugged.
                    """)
            }

            Divider()

            Toggle("Open somnus at login", isOn: Binding(
                get: { installation.loginItem.isRequested },
                set: { installation.setLoginItemEnabled($0) }))

            Text(installation.loginItem.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if installation.loginItem == .awaitingApproval {
                Button("Open Login Items & Extensions") {
                    installation.openSystemSettingsLoginItems()
                }
            }

            Divider()

            Stepper(value: warnThreshold, in: (engine.actThreshold + 1)...PowerPreferences.warnCeiling) {
                Text("Warn at \(engine.warnThreshold)% battery")
            }
            Stepper(value: actThreshold, in: PowerPreferences.actRange) {
                Text("Turn Stay Awake off at \(engine.actThreshold)% battery")
            }

            Text("""
                On battery with Stay Awake on, somnus warns you at the first threshold and switches \
                to Normal Sleep at the second. With the lid closed it then sleeps the Mac \
                immediately; with the lid open it only changes the mode and lets the usual idle \
                timer take over. If somnus caused that switch, it restores Stay Awake after the \
                battery recovers to \(engine.actThreshold + SafetyNetPolicy.restoreMargin)%. A state you turned off yourself \
                stays off.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if let reason = health.acAwareLastFailureReason {
                Advisory(text: "AC-aware mode is not working: \(reason)")
            }

            Toggle("AC-aware mode", isOn: Binding(
                get: { engine.acAwareModeEnabled },
                set: { engine.acAwareModeEnabled = $0 }))

            Text("""
                Turns Stay Awake on when you plug in and off when you unplug. Changing the toggle \
                by hand still wins, until the next time the power source changes.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var monitoringTitle: String {
        if !health.isMonitoring { return "Battery monitoring is off" }
        if health.monitoringDegradedReason != nil { return "Watching every minute" }
        if !health.safetyNetArmed { return "Safety net is not armed" }
        return "Safety net is armed"
    }

    private var monitoringSymbol: String {
        if !health.isMonitoring || !health.safetyNetArmed { return "exclamationmark.octagon.fill" }
        if health.monitoringDegradedReason != nil { return "exclamationmark.triangle.fill" }
        return "checkmark.shield.fill"
    }

    private var monitoringColour: Color {
        if !health.isMonitoring || !health.safetyNetArmed { return .red }
        if health.monitoringDegradedReason != nil { return .orange }
        return .green
    }

    /// The two thresholds are kept apart so the warning always arrives before
    /// the action. Clamping happens on the way in, not by rejecting the edit.
    private var warnThreshold: Binding<Int> {
        Binding(get: { engine.warnThreshold },
                set: { engine.warnThreshold = max($0, engine.actThreshold + 1) })
    }

    private var actThreshold: Binding<Int> {
        Binding(get: { engine.actThreshold },
                set: { engine.actThreshold = min($0, engine.warnThreshold - 1) })
    }
}

// MARK: - Power facts

private struct PowerFactsSection: View {

    let facts: PowerFacts?

    var body: some View {
        SectionCard(title: "Right now") {
            if let facts {
                FactRow(name: "Stay Awake", value: facts.sleepDisabled ? "On" : "Off")
                FactRow(name: "Battery", value: "\(facts.batteryPercent)%")
                FactRow(name: "Power source", value: facts.isOnAC ? "Power adapter" : "Battery")
                FactRow(name: "Charging", value: facts.isCharging ? "Yes" : "No")
                FactRow(name: "Lid", value: facts.lidClosed ? "Closed" : "Open")
                FactRow(name: "Hibernate mode", value: "\(facts.hibernateMode)")

                if facts.hibernateMode != 3 && facts.hibernateMode != 25 {
                    Advisory(text: """
                        The safety net will refuse to arm while hibernatemode is \
                        \(facts.hibernateMode): without a hibernation image, a battery that runs \
                        flat during sleep loses everything in memory, which is exactly what the \
                        safety net promises to prevent. somnus never changes this setting itself.
                        """)
                }
            } else {
                Text("Reading the power state…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FactRow: View {

    let name: String
    let value: String

    var body: some View {
        HStack {
            Text(name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}

// MARK: - Assertion inspector

private struct AssertionsSection: View {

    let assertions: [SleepAssertion]

    var body: some View {
        SectionCard(title: "What else is holding the Mac awake") {
            if externalAssertions.isEmpty {
                Text("Nothing. No other process is currently preventing sleep.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(externalAssertions) { assertion in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(assertion.processName) (pid \(assertion.pid))")
                        Text(subtitle(for: assertion))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("""
                    These are other applications' sleep assertions. somnus neither creates nor \
                    clears them: turning Stay Awake off will not override a process that is \
                    holding the Mac awake on its own.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `pmset` correctly reports Somnus's two assertions, but this section is
    /// specifically an inspector for *other* processes. Match the owning PID,
    /// not a display name or assertion description, so an unrelated process
    /// called Somnus is never hidden and both of our assertion types are.
    private var externalAssertions: [SleepAssertion] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return assertions.filter { $0.pid != ownPID }
    }

    private func subtitle(for assertion: SleepAssertion) -> String {
        guard let detail = assertion.detail, !detail.isEmpty else { return assertion.type }
        return "\(assertion.type): \(detail)"
    }
}

// MARK: - Chrome

private struct SectionCard<Content: View>: View {

    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.subheadline, design: .default).smallCaps())
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Advisory: View {

    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Warning")
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The louder cousin of `Advisory`, for the one state somnus cannot fix itself.
/// It always shows the literal recovery command and offers to copy it, because
/// the user is being asked to run something in Terminal that they have no reason
/// to know.
private struct RecoveryAdvisory: View {

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Action needed")
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(StayAwakeRecovery.copyCommandButtonTitle) {
                StayAwakeRecovery.copyCommand()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FooterView: View {

    let installation: HelperInstallation

    var body: some View {
        Text("somnus \(installation.appVersion) (\(installation.appBuild))")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
