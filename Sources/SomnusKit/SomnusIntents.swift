//  SomnusIntents.swift
//  SomnusKit: shared intents used by the widget, app, and CLI-facing module.
//
//  App Intents live HERE, not in Sources/SomnusControl/ or Sources/Somnus/.
//  Apple requires a control's intent to be a member of both the app and the
//  widget extension, but under PBXFileSystemSynchronizedRootGroup a file belongs
//  to exactly one target: so the intent has to come from the shared library
//  both targets link.
//
//  DELIBERATE: this file does NOT import WidgetKit, so it never calls
//  `ControlCenter.shared.reloadControls(ofKind:)`. SomnusKit is a static library
//  linked into somnusd as well as the app, the widget and the CLI; importing
//  WidgetKit here would autolink a UI framework into the root daemon. It is not
//  needed for the control path either: the system re-reads control state the
//  moment `perform()` returns, and nothing is cached. somnusd also broadcasts a
//  payload-free confirmed-change edge, so the running app asks Control Center
//  to reload when the same intent runs from Shortcuts. The CLI keeps its own
//  explicit reload so it remains prompt even when the app is not running.

import Foundation
import AppIntents

// MARK: - Set

/// The `SetValueIntent` behind the Control Center toggle, and the "Set Stay
/// Awake" action in Shortcuts and Automations.
///
/// `perform()` must not return until somnusd has confirmed the change: the
/// system re-reads control state the moment it returns, so an early return makes
/// the toggle visibly snap back. `SomnusClient.setStayAwake`
/// already has exactly that contract: it returns only once `pmset -a disablesleep`
/// has applied: so awaiting it is sufficient and no extra settling delay is needed.
public struct SetStayAwakeIntent: SetValueIntent {

    public static let title: LocalizedStringResource = "Set Stay Awake"

    public static let description = IntentDescription(
        "Turns Stay Awake on or off, so the Mac keeps running with the lid closed.")

    /// Never launches the app implicitly. Reads and OFF work without it; ON is
    /// accepted only when the already-running app has an armed battery guardian.
    public static let openAppWhenRun = false

    /// Populated by the system with the control's new state. Never set this.
    @Parameter(title: "On")
    public var value: Bool

    public init() {}

    public init(value: Bool) {
        self.value = value
    }

    public func perform() async throws -> some IntentResult {
        do {
            try await SomnusClient.shared.setStayAwake(value)
        } catch {
            throw SomnusIntentError(SomnusError.from(error))
        }
        return .result()
    }
}

// MARK: - Get

/// Reports the live mode. Makes somnus readable from Shortcuts and Automations,
/// e.g. "if Stay Awake is on, then …".
///
/// Like every other read in somnus this is a fresh round trip to somnusd, which
/// shells out to `pmset -g`. There is deliberately no cached mirror to consult.
public struct GetStayAwakeIntent: AppIntent {

    public static let title: LocalizedStringResource = "Get Stay Awake"

    public static let description = IntentDescription(
        "Reports whether Stay Awake is currently on. Reads the live system setting; nothing is cached.")

    public static let openAppWhenRun = false

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let isOn: Bool
        do {
            isOn = try await SomnusClient.shared.isStayAwakeOn()
        } catch {
            throw SomnusIntentError(SomnusError.from(error))
        }
        let dialog: IntentDialog = isOn
            ? "Stay Awake is on: the Mac stays running with the lid closed."
            : "Stay Awake is off: the Mac sleeps normally."
        return .result(value: isOn, dialog: dialog)
    }
}

// MARK: - Error surfacing

/// Wraps a `SomnusError` so Shortcuts, Control Center and Siri show somnus's own
/// message (for example, that the helper is not installed or not approved)
/// instead of a generic "the action failed".
struct SomnusIntentError: Error, CustomLocalizedStringResourceConvertible {

    let underlying: SomnusError

    init(_ underlying: SomnusError) {
        self.underlying = underlying
    }

    var localizedStringResource: LocalizedStringResource {
        let message = underlying.errorDescription ?? "somnus could not reach its helper."
        return "\(message)"
    }
}
