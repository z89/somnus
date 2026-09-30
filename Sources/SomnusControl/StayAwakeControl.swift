//  StayAwakeControl.swift
//  SomnusControl: the Control Center toggle.
//
//  `@main` goes directly on the ControlWidget: there is no ControlWidgetBundle
//  type in the macOS 26 SDK and WidgetBundleBuilder does not accept
//  ControlWidget.
//
//  DELIBERATE, do not "optimise":
//    * ControlWidgetToggle, not ControlWidgetButton: the whole point is showing
//      state, and a button cannot.
//    * Nothing is cached. `currentValue()` is a fresh XPC round trip to somnusd
//      on every render, so a mode changed from the terminal is already correct
//      the first time Control Center is opened. There is no UserDefaults mirror
//      (App Groups are unavailable on a free personal team anyway) and no
//      in-process memo in front of SomnusClient.

import WidgetKit
import SwiftUI
import AppIntents
import SomnusKit

// MARK: - The value the control renders

/// What one `currentValue()` round trip learned.
///
/// The provider's `Value` is deliberately richer than `Bool` so the control can
/// distinguish "off" from "somnusd could not be reached". Collapsing the two
/// into `false` would make the control *silently lie*: `SleepDisabled` can be 1
/// (set by hand or left over from before somnus was installed) while the
/// helper is unreachable, and a control reading "Normal Sleep" in that state is
/// worse than one that visibly fails. `previewValue` is gallery-only and is
/// not the error fallback.
struct StayAwakeValue: Equatable {

    enum DisplayState: Equatable {
        case unavailable
        case appNotRunning
        case unprotected
        case safetyNetOff
        case monitoringDegraded
        case normalSleep(acAware: Bool)
        case stayAwake(acAware: Bool)
    }

    /// `true` when `SleepDisabled` is 1. Meaningless unless `helperReachable`.
    let isOn: Bool

    /// `false` when somnusd is not installed, not yet approved, or refused us.
    let helperReachable: Bool
    let appRunning: Bool
    let safetyNetArmed: Bool
    let monitoringDegraded: Bool
    let acAwareModeEnabled: Bool

    static let unavailable = StayAwakeValue(isOn: false,
                                             helperReachable: false,
                                             appRunning: false,
                                             safetyNetArmed: false,
                                             monitoringDegraded: false,
                                             acAwareModeEnabled: false)

    var displayState: DisplayState {
        guard helperReachable else { return .unavailable }
        guard appRunning else { return isOn ? .unprotected : .appNotRunning }
        guard safetyNetArmed else { return .safetyNetOff }
        guard !monitoringDegraded else { return .monitoringDegraded }
        return isOn
            ? .stayAwake(acAware: acAwareModeEnabled)
            : .normalSleep(acAware: acAwareModeEnabled)
    }

    var stateTitle: LocalizedStringResource {
        switch displayState {
        case .unavailable:                    return "Unavailable"
        case .appNotRunning:                  return "App Not Running"
        case .unprotected:                    return "Unprotected"
        case .safetyNetOff:                   return "Safety Net Off"
        case .monitoringDegraded:             return "Monitoring Degraded"
        case .normalSleep(acAware: true):     return "Normal Sleep · AC Auto"
        case .normalSleep(acAware: false):    return "Normal Sleep"
        case .stayAwake(acAware: true):       return "Stay Awake · AC Auto"
        case .stayAwake(acAware: false):      return "Stay Awake"
        }
    }

    /// `cup.and.saucer.fill` awake, `cup.and.saucer` asleep: and a warning
    /// triangle when we genuinely do not know, which is the honest third case.
    var symbolName: String {
        guard helperReachable else { return "exclamationmark.triangle" }
        guard appRunning, safetyNetArmed else { return "exclamationmark.triangle.fill" }
        guard !monitoringDegraded else { return "exclamationmark.triangle" }
        return isOn ? "cup.and.saucer.fill" : "cup.and.saucer"
    }
}

// MARK: - The control

#if !SOMNUS_CONTROL_TESTS
@main
#endif
struct StayAwakeControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SomnusConstants.controlKind, provider: Provider()) { value in
            ControlWidgetToggle(isOn: value.isOn, action: SetStayAwakeIntent()) {
                Text("Stay Awake")
            } valueLabel: { _ in
                // Driven by the value we actually read, not by the system's
                // optimistic flag: after a failed write the toggle must fall
                // back to the truth on the next render, not to what was tapped.
                Label {
                    Text(value.stateTitle)
                } icon: {
                    Image(systemName: value.symbolName)
                }
            }
            // OFF is always a recovery action. ON additionally requires the
            // live battery guardian that somnusd enforces at its boundary.
            .disabled(!value.helperReachable
                      || (!value.isOn && (!value.appRunning || !value.safetyNetArmed)))
        }
        .displayName("Stay Awake")
        .description("Keeps the Mac awake with the lid closed.")
    }

    struct Provider: ControlValueProvider {

        /// Gallery only: not the loading/error fallback.
        var previewValue: StayAwakeValue {
            StayAwakeValue(isOn: false,
                           helperReachable: true,
                           appRunning: true,
                           safetyNetArmed: true,
                           monitoringDegraded: false,
                           acAwareModeEnabled: false)
        }

        /// Total by construction: it never propagates, because the SDK does not
        /// document what the control renders when this throws, and an
        /// undefined-looking control is not an acceptable outcome.
        ///
        /// The version probe is an upgrade-compatibility gate: build 1 helpers
        /// do not implement `getControlStatus`. Once compatible, all live power
        /// and monitoring fields come from one atomic helper snapshot. The
        /// shared client performs and caches that probe per XPC connection.
        func currentValue() async throws -> StayAwakeValue {
            do {
                let status = try await SomnusClient.shared.controlStatus()
                return StayAwakeValue(isOn: status.stayAwakeOn,
                                      helperReachable: true,
                                      appRunning: status.appRunning,
                                      safetyNetArmed: status.safetyNetArmed,
                                      monitoringDegraded: status.monitoringDegraded,
                                      acAwareModeEnabled: status.acAwareModeEnabled)
            } catch {
                if case .helperVersionMismatch = SomnusError.from(error) {
                    return .unavailable
                }
                // SomnusClient has already invalidated the failed XPC session.
                // Yield briefly so launchd can replace a helper interrupted by
                // an update, then make the compatibility read on a fresh
                // connection. Before this, both reads reused the same broken
                // session and Control Center cached `.unavailable` indefinitely.
                try? await Task.sleep(for: .milliseconds(200))
                // Health metadata is newer than the original power API. If it
                // is temporarily unavailable during a helper upgrade, keep the
                // toggle usable whenever the live SleepDisabled read works.
                do {
                    return StayAwakeValue(
                        isOn: try await SomnusClient.shared.isStayAwakeOn(),
                        helperReachable: true,
                        appRunning: false,
                        safetyNetArmed: false,
                        monitoringDegraded: false,
                        acAwareModeEnabled: false)
                } catch {
                    return .unavailable
                }
            }
        }
    }
}
