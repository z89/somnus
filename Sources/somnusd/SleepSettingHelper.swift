//  SleepSettingHelper.swift
//  somnusd: the object exported over XPC, running as uid 0.
//
//  Power state remains limited to two operations: read or write SleepDisabled.
//  The monitoring-status methods below store only unprivileged, process-local
//  heartbeat metadata; there are no debug entry points and no `sleepnow` (that
//  needs no root and lives in the unprivileged app).
//
//  CONCURRENCY (SWIFT_VERSION = 5.0: the compiler checks none of this):
//    * NSXPC delivers method calls on a concurrent queue, and reply blocks may
//      therefore be entered on several threads at once. Nothing here relies on
//      them arriving serially.
//    * The instance holds NO power state and NO cache. Its mutable state is
//      `admission`, a counting semaphore that bounds how much work may be
//      queued, and `openOffBatch`, guarded by `offBatchLock`. Neither says
//      anything about the machine.
//    * All `pmset` work is hopped onto `workQueue`, a private SERIAL queue, so
//      a read can never observe a half-applied write and two writes can never
//      race. The reply block is invoked exactly once, either from that queue or
//      synchronously on the admission-refusal path.
//
//  BACKPRESSURE: every peer that satisfies the listener's code-signing
//  requirement and the delegate's principal check may still call
//  `setSleepDisabled` in a tight loop, and each call spawns a root subprocess
//  that rewrites a system plist. Unbounded, that queue grows without limit and
//  the daemon serialises through it for as long as the attacker keeps calling.
//  `admission` caps the depth: past it, calls are refused IMMEDIATELY rather
//  than enqueued, so the cost of a flood is one rejected reply per call.
//  Off requests are never refused. Instead they join the queued off write
//  that has not started yet, so a flood of them adds at most one job.

import Foundation
import SomnusKit
import os

final class SleepSettingHelper: NSObject, SomnusHelperProtocol {

    /// Maximum number of `pmset` invocations queued or running at once.
    ///
    /// There are exactly three legitimate clients (app, widget, CLI), each of
    /// which issues at most a couple of calls at a time, and a healthy `pmset`
    /// completes in milliseconds: so a real workload never reaches this. It is
    /// large enough to absorb a launch-time burst from all three at once and
    /// small enough that the queue drains inside one `PMSet.worstCaseDuration`
    /// even if the head of it wedges.
    private static let maxQueuedRequests = 8

    /// Private serial queue. Every `pmset` invocation, read or write, runs
    /// here, so subprocess spawns are serialised regardless of how NSXPC
    /// schedules the incoming calls. Serialisation is a deliberate safety
    /// property; `PMSet.run` is bounded so it can never be wedged permanently.
    private let workQueue = DispatchQueue(label: "com.z89.somnus.helper.pmset",
                                          qos: .userInitiated)

    /// Bounds the depth of `workQueue`. Acquired with a zero timeout (a
    /// try-acquire, never a block: an XPC delivery thread must not be parked
    /// here) and released when the queued work finishes.
    private let admission = DispatchSemaphore(value: SleepSettingHelper.maxQueuedRequests)
    private let monitoring = MonitoringHeartbeatStore()

    /// Replies waiting on one queued off write.
    private final class OffBatch {
        var replies: [(Error?) -> Void] = []
    }

    /// The queued off write that new off requests may still join: it has not
    /// started, and no on write has been queued behind it.
    private var openOffBatch: OffBatch?
    private let offBatchLock = NSLock()
    private var watchdog: DispatchSourceTimer!

    private let log = Logger(subsystem: SomnusConstants.machServiceName, category: "helper")

    override init() {
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + .seconds(15),
                       repeating: .seconds(15),
                       leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.runSafetyWatchdogIfNeeded() }
        timer.resume()
        watchdog = timer
    }

    // MARK: - SomnusHelperProtocol

    @objc func getSleepDisabled(reply: @escaping (Bool, Error?) -> Void) {
        guard admission.wait(timeout: .now()) == .success else {
            log.error("getSleepDisabled refused: more than \(Self.maxQueuedRequests, privacy: .public) requests already queued")
            reply(false, Self.busyError.asNSError)
            return
        }
        workQueue.async { [log, admission] in
            defer { admission.signal() }
            do {
                let disabled = try PMSet.readSleepDisabled()
                reply(disabled, nil)
            } catch {
                let somnus = SomnusError.from(error)
                // `.private`: this embeds `pmset`'s stderr, produced by a root
                // process. Any local user can read the daemon's log with
                // `log stream`, so nothing derived from a root subprocess is
                // marked public.
                log.error("getSleepDisabled failed: \(somnus.localizedDescription, privacy: .private)")
                // A Swift enum cannot cross NSXPC; ship the bridged NSError.
                reply(false, somnus.asNSError)
            }
        }
    }

    @objc func setSleepDisabled(_ enabled: Bool, reply: @escaping (Error?) -> Void) {
        // Off is the safe direction and is never refused for load: a burst of
        // reads must not be able to block the safety net's shutoff.
        guard enabled else {
            enqueueOffWrite(reply: reply)
            return
        }
        guard admission.wait(timeout: .now()) == .success else {
            log.error("setSleepDisabled refused: more than \(Self.maxQueuedRequests, privacy: .public) requests already queued")
            reply(Self.busyError.asNSError)
            return
        }
        // Close the open off batch, so a later off request queues behind this
        // on write instead of running ahead of it.
        offBatchLock.lock()
        openOffBatch = nil
        workQueue.async { [log, admission, monitoring] in
            defer { admission.signal() }
            do {
                let status = monitoring.snapshot()
                guard status.appRunning, status.safetyNetArmed else {
                    reply(SomnusError.safetyNetUnavailable.asNSError)
                    return
                }
                try PMSet.writeSleepDisabled(true)
                SomnusStateChangeSignal.post()
                log.notice("disablesleep set to 1")
                reply(nil)
            } catch {
                let somnus = SomnusError.from(error)
                log.error("setSleepDisabled failed: \(somnus.localizedDescription, privacy: .private)")
                reply(somnus.asNSError)
            }
        }
        offBatchLock.unlock()
    }

    /// Joins the open off batch, or queues a new one. The batch closes when its
    /// write starts, so every reply reports a write that began after its
    /// request arrived.
    private func enqueueOffWrite(reply: @escaping (Error?) -> Void) {
        offBatchLock.lock()
        defer { offBatchLock.unlock() }
        if let batch = openOffBatch {
            batch.replies.append(reply)
            return
        }
        let batch = OffBatch()
        batch.replies.append(reply)
        openOffBatch = batch
        workQueue.async { [weak self, log] in
            guard let self else { return }
            self.offBatchLock.lock()
            if self.openOffBatch === batch { self.openOffBatch = nil }
            let replies = batch.replies
            self.offBatchLock.unlock()

            let result: Error?
            do {
                try PMSet.writeSleepDisabled(false)
                // The read-back inside `writeSleepDisabled` is the commit
                // point. Publish only after it succeeds, and carry no value:
                // every listener re-reads live truth, so notification
                // coalescing can never make a stale intermediate state stick.
                SomnusStateChangeSignal.post()
                log.notice("disablesleep set to 0 for \(replies.count, privacy: .public) request(s)")
                result = nil
            } catch {
                let somnus = SomnusError.from(error)
                log.error("setSleepDisabled failed: \(somnus.localizedDescription, privacy: .private)")
                result = somnus.asNSError
            }
            replies.forEach { $0(result) }
        }
    }

    @objc func helperVersion(reply: @escaping (String) -> Void) {
        // Read from the executable's embedded __TEXT,__info_plist section
        // (CREATE_INFOPLIST_SECTION_IN_BINARY = YES). No subprocess, no state,
        // no work queue: so no admission control is needed either.
        reply(SleepSettingHelper.version)
    }

    @objc func getControlStatus(
        reply: @escaping (Bool, Bool, Bool, Bool, Bool, Error?) -> Void
    ) {
        guard admission.wait(timeout: .now()) == .success else {
            reply(false, false, false, false, false, Self.busyError.asNSError)
            return
        }
        workQueue.async { [monitoring, admission] in
            defer { admission.signal() }
            do {
                let disabled = try PMSet.readSleepDisabled()
                let status = monitoring.snapshot()
                reply(disabled,
                      status.appRunning,
                      status.safetyNetArmed,
                      status.monitoringDegraded,
                      status.acAwareModeEnabled,
                      nil)
            } catch {
                reply(false, false, false, false, false,
                      SomnusError.from(error).asNSError)
            }
        }
    }

    @objc func reportAppStatus(_ running: Bool,
                               safetyNetArmed: Bool,
                               monitoringDegraded: Bool,
                               acAwareModeEnabled: Bool,
                               reply: @escaping (Error?) -> Void) {
        monitoring.report(running: running,
                          safetyNetArmed: safetyNetArmed,
                          monitoringDegraded: monitoringDegraded,
                          acAwareModeEnabled: acAwareModeEnabled)
        if !running || !safetyNetArmed {
            workQueue.async { [weak self] in self?.runSafetyWatchdogIfNeeded() }
        }
        reply(nil)
    }

    /// `SleepDisabled` outlives every process, so liveness is enforced here at
    /// the privileged boundary. One check runs when protection is explicitly
    /// lost or a 90-second lease expires; failures retry on the bounded timer.
    private func runSafetyWatchdogIfNeeded() {
        guard monitoring.shouldRunWatchdog() else { return }
        do {
            if try PMSet.readSleepDisabled() {
                try PMSet.writeSleepDisabled(false)
                SomnusStateChangeSignal.post()
                log.fault("Battery protection disappeared; the watchdog restored Normal Sleep.")
            }
            monitoring.markWatchdogHandled()
        } catch {
            let somnus = SomnusError.from(error)
            log.fault("Safety watchdog could not restore Normal Sleep: \(somnus.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Backpressure

    /// Returned when `admission` is exhausted. `SomnusError`'s cases are stable
    /// and shared with every client, so this reuses `pmsetFailed`. That is
    /// accurate in the sense that matters to the caller: the
    /// privileged operation did not run, and retrying later may work.
    private static let busyError = SomnusError.pmsetFailed(
        status: -1,
        stderr: "somnusd is busy: too many requests are already queued")

    // MARK: - Version

    /// `"<CFBundleShortVersionString> (<CFBundleVersion>)"`, e.g. `"0.1.0 (1)"`.
    /// Clients compare this against their own bundle version to detect skew
    /// after an app upgrade.
    static let version: String = SomnusConstants.version()
}
