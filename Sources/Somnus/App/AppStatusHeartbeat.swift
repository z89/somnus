import Foundation
import Observation
import SomnusKit
import WidgetKit

/// Keeps Control Center informed that the in-process battery monitor is alive.
/// Engine state changes are observed and published immediately; the 30-second
/// task only renews a liveness lease. The helper expires that lease after 90
/// seconds, so force-quit and crashes are eventually visible even though they
/// cannot run a shutdown hook.
@MainActor
final class AppStatusHeartbeat {
    static let shared = AppStatusHeartbeat()
    static let interval: Duration = .seconds(30)

    private var task: Task<Void, Never>?
    private var lastReported: ReportedStatus?
    private var reportingWasUnavailable = false
    private var observationGeneration = 0

    // Status changes and the liveness lease can arrive while an XPC report is
    // suspended. Coalesce them through one publisher so a rapid A -> B -> A
    // sequence can never finish by recording the stale middle state.
    private var sendInFlight = false
    private var sendRequested = false
    private var requestedRunning = true
    private var forceRequested = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    private struct ReportedStatus: Equatable {
        let running: Bool
        let safetyNetArmed: Bool
        let monitoringDegraded: Bool
        let acAwareModeEnabled: Bool
        /// Included in the local fingerprint even though the helper already
        /// reads this value itself. A change must trigger another pair of
        /// Control Center reloads when the engine's immediate reload is missed.
        let stayAwakeOn: Bool?
    }

    private init() {}

    func start() {
        guard task == nil else { return }
        observationGeneration += 1
        let generation = observationGeneration
        task = Task { @MainActor [weak self] in
            // Do not advertise protection until the engine has completed a
            // real sample. `activate()` starts its own refresh; refresh() also
            // waits for a coalesced pass when that sample is already running.
            await PowerEngineBridge.engine.refresh()
            guard !Task.isCancelled else { return }
            self?.observeStatusChanges(generation: generation)

            while !Task.isCancelled {
                guard let self else { return }
                // This is a liveness lease, not state polling. Actual state
                // changes arrive immediately through Observation below.
                await self.send(running: true, force: true)
                do {
                    try await Task.sleep(for: Self.interval, tolerance: .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    func stop() async {
        observationGeneration += 1
        let heartbeatTask = task
        task = nil
        heartbeatTask?.cancel()
        await heartbeatTask?.value
        await send(running: false, force: true)
    }

    /// Arms a one-shot Observation registration, then re-arms before publishing
    /// each change. The 30-second task above now proves only that the process is
    /// alive; it is no longer how Control Center learns about state changes.
    private func observeStatusChanges(generation: Int) {
        guard task != nil, generation == observationGeneration else { return }
        withObservationTracking {
            _ = reportedStatus(running: true)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.task != nil,
                      generation == self.observationGeneration else { return }
                // Re-arm first so a second change during the awaited XPC call
                // is captured and folded into the serialized publisher.
                self.observeStatusChanges(generation: generation)
                await self.send(running: true, force: false)
            }
        }
    }

    private func reportedStatus(running: Bool) -> ReportedStatus {
        let health = PowerEngineBridge.health
        return ReportedStatus(
            running: running,
            safetyNetArmed: health.lastEvaluation != nil
                && health.isMonitoring
                && health.safetyNetArmed
                && health.idleAssertionsHealthy,
            monitoringDegraded: health.monitoringDegradedReason != nil,
            acAwareModeEnabled: PowerEngineBridge.engine.acAwareModeEnabled,
            stayAwakeOn: PowerEngineBridge.stayAwakeIsKnown
                ? PowerEngineBridge.engine.facts?.sleepDisabled
                : nil)
    }

    /// Serializes heartbeat and change-triggered reports. A caller that arrives
    /// during an XPC await requests a fresh pass and waits for that pass, rather
    /// than racing an older snapshot into `lastReported` afterwards.
    private func send(running: Bool, force: Bool) async {
        guard !sendInFlight else {
            sendRequested = true
            requestedRunning = running
            forceRequested = forceRequested || force
            await withCheckedContinuation { continuation in
                sendWaiters.append(continuation)
            }
            return
        }

        sendInFlight = true
        var nextRunning = running
        var nextForce = force
        defer {
            sendInFlight = false
            let waiters = sendWaiters
            sendWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        while true {
            sendRequested = false
            requestedRunning = nextRunning
            forceRequested = false

            await publish(running: nextRunning, force: nextForce)

            guard sendRequested else { return }
            nextRunning = requestedRunning
            nextForce = forceRequested
        }
    }

    private func publish(running: Bool, force: Bool) async {
        let status = reportedStatus(running: running)
        guard force || status != lastReported else { return }
        do {
            try await SomnusClient.shared.reportAppStatus(
                running: status.running,
                safetyNetArmed: status.safetyNetArmed,
                monitoringDegraded: status.monitoringDegraded,
                acAwareModeEnabled: status.acAwareModeEnabled)
            let recovered = reportingWasUnavailable
            reportingWasUnavailable = false
            if status != lastReported || recovered {
                lastReported = status
                reloadControlCenterReliably()
            }
        } catch {
            // Expiry in the helper is the fail-safe if reporting is unavailable.
            // Remember the edge: once launchd makes the helper reachable again,
            // the first successful lease refresh must also clear any warning
            // Control Center cached during the outage.
            reportingWasUnavailable = true
        }
    }

    /// User-facing recovery hook. Normal updates remain event-driven; this is
    /// also a no-reboot escape hatch if macOS itself holds a stale rendering.
    func reloadControlCenterNow() {
        reloadControlCenterReliably()
    }

    private func reloadControlCenterReliably() {
        ControlCenter.shared.reloadControls(ofKind: SomnusConstants.controlKind)
        // A bounded second request covers widget-host replacement or a reload
        // coalesced with the state-changing event. It is event-driven, not a
        // polling loop, and the provider re-reads live truth both times.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            ControlCenter.shared.reloadControls(ofKind: SomnusConstants.controlKind)
        }
    }
}
