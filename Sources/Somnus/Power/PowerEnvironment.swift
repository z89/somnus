//  PowerEnvironment.swift
//  somnus: power environment.
//
//  Every effect the engine can have on the world, as injectable closures. This
//  is the seam that makes the safety net testable:
//
//    * `requestSleepNow` is bound to `pmset sleepnow` in `.live` and NOWHERE
//      else. Tests bind it to a closure that records the request, so the
//      lid-closed path is proved without ever sleeping a machine.
//    * `notify` is bound to the real notification centre only in `.live`, so no
//      test or preview can post a user-visible notification.
//    * `now` is injectable so the failure-retry back-off is testable without
//      waiting a minute.
//    * `setIdleAssertions` is bound to the real IOPMAssertions only in `.live`,
//      so no test can hold the host's display awake.
//    * `observeStayAwakeChanges` is bound to a payload-free Darwin notification
//      posted by somnusd only after a confirmed write. Tests capture the
//      callback and drive it directly; they never register with the real
//      notification centre.
//    * `reloadControlCenter` is bound to WidgetKit only in `.live`. It exists
//      because the Control Center toggle re-renders when it is asked to, and
//      an engine-driven flip (safety net, AC-aware) that does not ask leaves
//      the widget showing a state the machine is no longer in.

import AppKit
import Foundation
import SomnusKit
import UserNotifications
import WidgetKit
import os

public enum StayAwakeWriteOrigin: Sendable, Equatable {
    case safetyNet
    case userOrAutomation
}

@MainActor
public struct PowerEnvironment {

    // Reads
    public var readPowerSource: () async -> PowerSourceSample
    public var readLidClosed: () async -> Bool?
    public var readSleepSettings: () async -> SleepSettings
    public var readStayAwake: () async throws -> Bool
    public var readAssertions: () async -> [SleepAssertion]
    /// `SleepDisabled` without a subprocess, or `nil` if it cannot be read.
    /// Synchronous and ~10µs, so the engine can reconcile assertions as soon as
    /// a confirmed-change event arrives; the `pmset -g` read above stays the
    /// authority for everything else.
    public var readSleepDisabledFast: () -> Bool?

    // Writes / effects
    public var setStayAwake: (Bool, StayAwakeWriteOrigin) async throws -> Void
    public var requestSleepNow: () async -> Bool
    public var notify: (PowerNotice) -> Void
    public var prepareNotifications: () -> Void
    /// Holds (`true`) or releases (`false`) the idle assertions that keep the
    /// display and the system off their idle timers. Idempotent; the engine
    /// reconciles it to the observed Stay Awake state on every pass.
    /// Returns whether the required display assertion matches the request.
    public var setIdleAssertions: (Bool) -> Bool
    /// Asks Control Center to re-read the toggle. Called after every confirmed
    /// Stay Awake write so the widget cannot render a stale state.
    public var reloadControlCenter: () -> Void
    /// Registers for confirmed Stay Awake writes. The returned closure removes
    /// the observation and is safe to call more than once.
    public var observeStayAwakeChanges: (@escaping () -> Void) -> () -> Void
    public var observeManualOffIntents: (@escaping () -> Void) -> () -> Void

    // Plumbing
    public var makeRunLoopSource: (UnsafeMutableRawPointer?) -> CFRunLoopSource?
    public var loadPreferences: () -> PowerPreferences
    public var savePreferences: (PowerPreferences) -> Void
    public var now: () -> Date

    public init(readPowerSource: @escaping () async -> PowerSourceSample,
                readLidClosed: @escaping () async -> Bool?,
                readSleepSettings: @escaping () async -> SleepSettings,
                readStayAwake: @escaping () async throws -> Bool,
                readAssertions: @escaping () async -> [SleepAssertion],
                readSleepDisabledFast: @escaping () -> Bool?,
                setStayAwake: @escaping (Bool, StayAwakeWriteOrigin) async throws -> Void,
                requestSleepNow: @escaping () async -> Bool,
                notify: @escaping (PowerNotice) -> Void,
                prepareNotifications: @escaping () -> Void,
                setIdleAssertions: @escaping (Bool) -> Bool,
                reloadControlCenter: @escaping () -> Void,
                observeStayAwakeChanges: @escaping (@escaping () -> Void) -> () -> Void,
                observeManualOffIntents: @escaping (@escaping () -> Void) -> () -> Void,
                makeRunLoopSource: @escaping (UnsafeMutableRawPointer?) -> CFRunLoopSource?,
                loadPreferences: @escaping () -> PowerPreferences,
                savePreferences: @escaping (PowerPreferences) -> Void,
                now: @escaping () -> Date) {
        self.readPowerSource = readPowerSource
        self.readLidClosed = readLidClosed
        self.readSleepSettings = readSleepSettings
        self.readStayAwake = readStayAwake
        self.readAssertions = readAssertions
        self.readSleepDisabledFast = readSleepDisabledFast
        self.setStayAwake = setStayAwake
        self.requestSleepNow = requestSleepNow
        self.notify = notify
        self.prepareNotifications = prepareNotifications
        self.setIdleAssertions = setIdleAssertions
        self.reloadControlCenter = reloadControlCenter
        self.observeStayAwakeChanges = observeStayAwakeChanges
        self.observeManualOffIntents = observeManualOffIntents
        self.makeRunLoopSource = makeRunLoopSource
        self.loadPreferences = loadPreferences
        self.savePreferences = savePreferences
        self.now = now
    }

    /// The real machine. IOKit and `pmset` work happens on detached tasks so the
    /// main actor never blocks on a subprocess.
    public static let live = PowerEnvironment(
        readPowerSource: { await Task.detached { PowerSourceSampler.sample() }.value },
        readLidClosed: { await Task.detached { LidSensor.lidClosed() }.value },
        readSleepSettings: { await Task.detached { PMSet.readSleepSettings() }.value },
        readStayAwake: { try await SomnusClient.shared.isStayAwakeOn() },
        readAssertions: { await Task.detached { PMSet.readAssertions() }.value },
        readSleepDisabledFast: { SleepDisabledSensor.read() },
        setStayAwake: { on, origin in
            try await SomnusClient.shared.setStayAwake(
                on, explicitOffIntent: origin == .userOrAutomation)
        },
        // The ONLY binding of the sleep path to real machinery.
        requestSleepNow: { await Task.detached { SystemSleeper.sleepNow() }.value },
        notify: { PowerNotifier.shared.post($0) },
        prepareNotifications: { PowerNotifier.shared.prepare() },
        // The ONLY binding of the idle assertions to real IOKit.
        setIdleAssertions: { WakeAssertion.shared.set($0) },
        reloadControlCenter: {
            ControlCenter.shared.reloadControls(ofKind: SomnusConstants.controlKind)
        },
        observeStayAwakeChanges: { handler in
            SomnusStateChangeSignal.observe(handler)
        },
        observeManualOffIntents: { handler in
            SomnusStateChangeSignal.observeManualOffIntent(handler)
        },
        makeRunLoopSource: { context in
            PowerSourceSampler.makeRunLoopSource(callback: somnusPowerSourceCallback,
                                                 context: context)
        },
        loadPreferences: { PowerPreferenceStore.load() },
        savePreferences: { PowerPreferenceStore.save($0) },
        now: { Date() })
}

// MARK: - Preference persistence

/// User preferences only: never power state. `SleepDisabled`, battery, lid and
/// hibernatemode are re-read from the system on every evaluation and are never
/// mirrored here.
public enum PowerPreferenceStore {

    private enum Key {
        static let acAware = "SomnusACAwareModeEnabled"
        static let warn = "SomnusWarnThreshold"
        static let act = "SomnusActThreshold"
    }

    public static func load(from defaults: UserDefaults = .standard) -> PowerPreferences {
        let fallback = PowerPreferences.defaults
        let warn = defaults.object(forKey: Key.warn) as? Int ?? fallback.warnThreshold
        let act = defaults.object(forKey: Key.act) as? Int ?? fallback.actThreshold
        let acAware = defaults.object(forKey: Key.acAware) as? Bool ?? fallback.acAwareModeEnabled
        return PowerPreferences.clamped(warn: warn, act: act, acAware: acAware)
    }

    public static func save(_ preferences: PowerPreferences, to defaults: UserDefaults = .standard) {
        defaults.set(preferences.acAwareModeEnabled, forKey: Key.acAware)
        defaults.set(preferences.warnThreshold, forKey: Key.warn)
        defaults.set(preferences.actThreshold, forKey: Key.act)
    }
}

// MARK: - Notifications

/// File-scope so the notification-centre completion handlers: which are not
/// main-actor isolated: can log without hopping.
private let powerNotifyLog = Logger(subsystem: SomnusConstants.appBundleID,
                                    category: "power.notify")

public enum NotificationPermission: String {
    case notRequested = "not requested"
    case allowed = "allowed"
    case provisional = "provisional"
    case denied = "denied"
    case unavailable = "unavailable"
    case unknown = "unknown"

    public var canDeliverWarnings: Bool {
        self == .allowed || self == .provisional
    }
}

/// Posts the safety net's notices. Reached only through
/// `PowerEnvironment.live.notify`, so nothing but the running app can post.
@MainActor
public final class PowerNotifier {

    public static let shared = PowerNotifier()

    private init() {}

    /// Warms the notification service without asking an out-of-context
    /// permission question at login. Explicit setup owns the system prompt.
    public func prepare() {
        Task { @MainActor in _ = await permission() }
    }

    public func permission() async -> NotificationPermission {
        guard let center = Self.center() else { return .unavailable }
        return Self.permission(from: await center.notificationSettings().authorizationStatus)
    }

    /// Setup calls this immediately after explaining why the low-battery net
    /// needs visible warnings. macOS remembers the answer, so repeated setup is
    /// idempotent and never manufactures a replacement prompt.
    public func requestPermissionForSetup() async -> NotificationPermission {
        guard let center = Self.center() else { return .unavailable }
        let current = await center.notificationSettings().authorizationStatus
        if current == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                powerNotifyLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return Self.permission(from: await center.notificationSettings().authorizationStatus)
    }

    /// There is no API that may grant this permission on the user's behalf.
    /// Once denied, take them directly to Somnus's pane instead of asking them
    /// to find it in System Settings.
    @discardableResult
    public func openSystemSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(SomnusConstants.appBundleID)") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    public func post(_ notice: PowerNotice) {
        guard let center = Self.center() else {
            // Not running from an app bundle (unit-test harness, CLI). Log and
            // move on: never crash the safety net over a notification.
            powerNotifyLog.notice("Notice (not posted, no bundle): \(notice.body, privacy: .public)")
            return
        }

        Task { @MainActor in
            let permission = Self.permission(
                from: await center.notificationSettings().authorizationStatus)
            guard permission.canDeliverWarnings else {
                powerNotifyLog.error("Notification not delivered because permission is \(permission.rawValue, privacy: .public).")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            if notice.isCritical { content.sound = .default }

            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            do {
                try await center.add(request)
            } catch {
                // The user must not be left thinking they were warned.
                powerNotifyLog.fault("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func permission(from status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .authorized: return .allowed
        case .provisional: return .provisional
        case .ephemeral: return .allowed
        @unknown default: return .unknown
        }
    }

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle
    /// identifier, so guard it rather than assume.
    private static func center() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
