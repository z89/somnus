import Foundation

struct MonitoringHeartbeatSnapshot: Equatable, Sendable {
    let appRunning: Bool
    let safetyNetArmed: Bool
    let monitoringDegraded: Bool
    let acAwareModeEnabled: Bool
}

/// Thread-safe, process-local status reported by the menu-bar app. No value is
/// persisted: after a daemon restart the app must prove it is alive again.
final class MonitoringHeartbeatStore: @unchecked Sendable {
    static let staleAfter: TimeInterval = 90

    private let lock = NSLock()
    private let timeout: TimeInterval
    private let startedAt: TimeInterval
    private var lastHeartbeatUptime: TimeInterval?
    private var hasReceivedReport = false
    /// Bumped by every protected report. A lapse is identified by the epoch
    /// it follows, so a later lapse is never mistaken for one already handled,
    /// even when the watchdog never observed the protected report in between.
    private var protectionEpoch = 0
    private var evaluatedEpoch = 0
    private var handledEpoch: Int?
    private var reportedRunning = false
    private var reportedSafetyNetArmed = false
    private var reportedMonitoringDegraded = false
    private var reportedACAwareModeEnabled = false

    init(timeout: TimeInterval = MonitoringHeartbeatStore.staleAfter,
         startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.timeout = timeout
        self.startedAt = startedAt
    }

    func report(running: Bool,
                safetyNetArmed: Bool,
                monitoringDegraded: Bool,
                acAwareModeEnabled: Bool,
                at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        hasReceivedReport = true
        reportedRunning = running
        reportedSafetyNetArmed = safetyNetArmed
        reportedMonitoringDegraded = monitoringDegraded
        reportedACAwareModeEnabled = acAwareModeEnabled
        lastHeartbeatUptime = running ? uptime : nil
        if running && safetyNetArmed { protectionEpoch += 1 }
        lock.unlock()
    }

    /// One watchdog action per lapse. A daemon that has just launched gets the
    /// same grace period as a live heartbeat; an explicit stopped/unprotected
    /// report is actionable immediately. Called only from the helper's serial
    /// work queue, so each call pairs with the `markWatchdogHandled` after it.
    func shouldRunWatchdog(
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let heartbeatFresh = reportedRunning
            && lastHeartbeatUptime.map { max(0, uptime - $0) <= timeout } == true
        let protected = heartbeatFresh && reportedSafetyNetArmed
        if protected { return false }

        let graceExpired = hasReceivedReport || max(0, uptime - startedAt) > timeout
        evaluatedEpoch = protectionEpoch
        return graceExpired && handledEpoch != protectionEpoch
    }

    func markWatchdogHandled() {
        lock.lock()
        handledEpoch = evaluatedEpoch
        lock.unlock()
    }

    func snapshot(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> MonitoringHeartbeatSnapshot {
        lock.lock()
        let last = lastHeartbeatUptime
        let running = reportedRunning
            && last.map { max(0, uptime - $0) <= timeout } == true
        let snapshot = MonitoringHeartbeatSnapshot(
            appRunning: running,
            safetyNetArmed: running && reportedSafetyNetArmed,
            monitoringDegraded: running && reportedMonitoringDegraded,
            acAwareModeEnabled: running && reportedACAwareModeEnabled)
        lock.unlock()
        return snapshot
    }
}
