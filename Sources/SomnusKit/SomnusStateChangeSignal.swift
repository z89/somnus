//  SomnusStateChangeSignal.swift
//  SomnusKit: cross-process edge notification for confirmed power changes.
//
//  The signal carries no value. Darwin notifications may be coalesced, so every
//  receiver must use it only as a reason to re-read `SleepDisabled` from the
//  helper or IORegistry. That preserves the system setting as the sole source
//  of truth while giving the always-running app an immediate, event-driven path
//  for writes made by Control Center, Shortcuts, the CLI, or AC-aware policy.

import Foundation

public enum SomnusStateChangeSignal {

    private static var notificationName: CFNotificationName {
        CFNotificationName(
            SomnusConstants.stayAwakeDidChangeNotification as CFString)
    }

    private static var manualOffName: CFNotificationName {
        CFNotificationName(SomnusConstants.manualOffIntentNotification as CFString)
    }

    /// Called by somnusd only after `pmset` success and independent read-back.
    public static func post() {
        post(notificationName)
    }

    /// Called by a client only after an explicit OFF was confirmed. Unlike the
    /// general edge, this also covers a redundant OFF when the mode was already
    /// off and therefore had no transition to observe.
    public static func postManualOffIntent() {
        post(manualOffName)
    }

    private static func post(_ name: CFNotificationName) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true)
    }

    /// Starts observing confirmed changes and returns an idempotent cancel
    /// closure. Delivery can arrive on any thread; callers that own actor-bound
    /// state must hop to their actor in `handler`.
    public static func observe(_ handler: @escaping () -> Void) -> () -> Void {
        let observation = Observation(name: notificationName, handler: handler)
        return { observation.cancel() }
    }

    public static func observeManualOffIntent(_ handler: @escaping () -> Void) -> () -> Void {
        let observation = Observation(name: manualOffName, handler: handler)
        return { observation.cancel() }
    }

    fileprivate final class Observation {
        private let lock = NSLock()
        private var isActive = true
        private let name: CFNotificationName
        private let handler: () -> Void

        init(name: CFNotificationName, handler: @escaping () -> Void) {
            self.name = name
            self.handler = handler
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                somnusStateChangeCallback,
                name.rawValue,
                nil,
                .deliverImmediately)
        }

        deinit {
            cancel()
        }

        func cancel() {
            lock.lock()
            guard isActive else {
                lock.unlock()
                return
            }
            isActive = false
            lock.unlock()

            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                name,
                nil)
        }

        fileprivate func receive() {
            lock.lock()
            let active = isActive
            lock.unlock()
            if active { handler() }
        }
    }
}

private let somnusStateChangeCallback: CFNotificationCallback = {
    _, observer, _, _, _ in
    guard let observer else { return }
    Unmanaged<SomnusStateChangeSignal.Observation>
        .fromOpaque(observer)
        .takeUnretainedValue()
        .receive()
}
