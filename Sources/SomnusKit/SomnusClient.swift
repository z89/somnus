//  SomnusClient.swift
//  SomnusKit: shared client for app, control, helper diagnostics and CLI.
//
//  Single entry point for every unprivileged client (widget, app, CLI).
//  NEVER caches: every read is a fresh round trip to somnusd, which runs
//  `pmset -g`. No UserDefaults mirror: App Groups are unavailable and a cache
//  would desync with terminal-driven changes.
//
//  EVERY call is bounded (see `Deadline`). Before that was true only two things
//  could resume the awaiting continuation: the XPC reply block and the
//  connection's error handler: and NEITHER fires when somnusd accepts the
//  connection and then never answers (e.g. a wedged `pmset` child holding its
//  serial work queue). The caller then awaited forever: in the app that parked
//  `PowerEngine.evaluate` with `evaluationInFlight = true` and its `defer`
//  unreachable, silently disabling the low-battery safety net for the life of
//  the process. The deadline lives HERE, in the shared client, so all four
//  clients inherit it; a per-caller timeout wrapper is exactly the drift that
//  produced this bug.

import Foundation

public actor SomnusClient {

    public static let shared = SomnusClient()

    private var connection: NSXPCConnection?
    private var statusProtocolVerifiedConnection: NSXPCConnection?

    private init() {}

    // MARK: - Deadlines

    /// How long a call may take before it is failed rather than awaited.
    ///
    /// Every value is an upper bound on "somnusd is alive and answering", not a
    /// performance target: a healthy `pmset` answers in milliseconds.
    private enum Deadline {
        /// `getSleepDisabled`. Covers a cold on-demand launchd spawn plus one
        /// in-flight write ahead of us on the daemon's serial queue. Kept well
        /// under the daemon's own worst case so that a caller polling on a
        /// timer (the battery safety net) always gets an answer and always
        /// runs its `defer`, even while the daemon is being un-wedged.
        static let read: TimeInterval = 10

        /// `setSleepDisabled`. Deliberately the longest, and deliberately
        /// LONGER than somnusd's own worst-case bounded write (PMSet: 15s
        /// SIGTERM + 3s SIGKILL grace + 1s abandon grace + 2s pipe drain =
        /// 21s), so that a genuinely slow `pmset` still succeeds and a killed
        /// one loses the race to the daemon's real `pmsetFailed` error: the
        /// user sees the true reason rather than a generic timeout. (A call
        /// queued behind others on the daemon's serial queue can still exceed
        /// this; that is the case the deadline exists for.) Still short enough
        /// that an intent's `perform()` returns before the system gives up.
        static let write: TimeInterval = 25

        /// `helperVersion`, used only to decide whether to offer installation
        /// UI. "Did not answer promptly" and "not installed" lead to the same
        /// UI, so this is short: a Control Center render must never hang on it.
        static let health: TimeInterval = 5
    }

    // MARK: - Public API

    /// `true` when `SleepDisabled` is 1, i.e. the Mac stays awake with the lid closed.
    public func isStayAwakeOn() async throws -> Bool {
        let helper = try proxy()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let box = helper.box
                box.register { continuation.resume(throwing: $0) }
                box.arm(Deadline.read)
                helper.remote.getSleepDisabled { enabled, error in
                    if let error {
                        box.resume(with: .failure(SomnusError.from(error)), into: continuation)
                    } else {
                        box.resume(with: .success(enabled), into: continuation)
                    }
                }
            }
        } catch {
            discard(helper.connection)
            throw error
        }
    }

    /// Turns Stay Awake on or off. Returns only once somnusd has confirmed that
    /// `pmset -a disablesleep` actually applied: a `SetValueIntent`'s
    /// `perform()` must not return before this does, or the toggle snaps back.
    public func setStayAwake(_ on: Bool, explicitOffIntent: Bool = true) async throws {
        let helper = try proxy()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let box = helper.box
                box.register { continuation.resume(throwing: $0) }
                box.arm(Deadline.write)
                helper.remote.setSleepDisabled(on) { error in
                    if let error {
                        box.resume(with: .failure(SomnusError.from(error)), into: continuation)
                    } else {
                        box.resume(with: .success(()), into: continuation)
                    }
                }
            }
            if !on, explicitOffIntent {
                SomnusStateChangeSignal.postManualOffIntent()
            }
        } catch {
            discard(helper.connection)
            throw error
        }
    }

    /// `true` when somnusd is reachable and answering. Never throws: callers
    /// use this to decide whether to offer installation UI.
    public func helperIsHealthy() async -> Bool {
        (try? await helperVersion()) != nil
    }

    /// The running helper's immutable bundle version. Callers use this before
    /// invoking methods introduced by a newer helper protocol during upgrades.
    public func helperVersion() async throws -> String {
        let helper = try proxy()
        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, Error>) in
                let box = helper.box
                box.register { continuation.resume(throwing: $0) }
                box.arm(Deadline.health)
                helper.remote.helperVersion { version in
                    box.resume(with: .success(version), into: continuation)
                }
            }
        } catch {
            discard(helper.connection)
            throw error
        }
    }

    /// Reads the live power mode and the app's most recent monitoring heartbeat
    /// in one XPC round trip, so Control Center cannot combine mismatched reads.
    public func controlStatus() async throws -> SomnusControlStatus {
        do {
            try await requireCurrentHelperVersion()
        } catch {
            // A repaired helper may already be waiting behind a connection to
            // the old build. Never let version skew become sticky.
            disconnect()
            throw error
        }
        let helper = try proxy()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let box = helper.box
                box.register { continuation.resume(throwing: $0) }
                box.arm(Deadline.read)
                helper.remote.getControlStatus { stayAwakeOn, appRunning, safetyNetArmed,
                                                 monitoringDegraded, acAwareModeEnabled, error in
                    if let error {
                        box.resume(with: .failure(SomnusError.from(error)), into: continuation)
                    } else {
                        box.resume(with: .success(SomnusControlStatus(
                            stayAwakeOn: stayAwakeOn,
                            appRunning: appRunning,
                            safetyNetArmed: safetyNetArmed,
                            monitoringDegraded: monitoringDegraded,
                            acAwareModeEnabled: acAwareModeEnabled)), into: continuation)
                    }
                }
            }
        } catch {
            discard(helper.connection)
            throw error
        }
    }

    /// Publishes unprivileged process health. The helper stores only the latest
    /// values and receipt time; this never reads or writes system power state.
    public func reportAppStatus(running: Bool,
                                safetyNetArmed: Bool,
                                monitoringDegraded: Bool,
                                acAwareModeEnabled: Bool) async throws {
        do {
            try await requireCurrentHelperVersion()
        } catch {
            disconnect()
            throw error
        }
        let helper = try proxy()
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let box = helper.box
                box.register { continuation.resume(throwing: $0) }
                box.arm(Deadline.health)
                helper.remote.reportAppStatus(running,
                                              safetyNetArmed: safetyNetArmed,
                                              monitoringDegraded: monitoringDegraded,
                                              acAwareModeEnabled: acAwareModeEnabled) { error in
                    if let error {
                        box.resume(with: .failure(SomnusError.from(error)), into: continuation)
                    } else {
                        box.resume(with: .success(()), into: continuation)
                    }
                }
            }
        } catch {
            discard(helper.connection)
            throw error
        }
    }

    /// Drop this process's cached XPC session before replacing or unregistering
    /// the helper. ServiceManagement's asynchronous unregister does not call
    /// its completion until the old daemon has been reaped; keeping our own
    /// connection alive while waiting would deadlock that handoff.
    public func disconnect() {
        connection?.invalidate()
        connection = nil
        statusProtocolVerifiedConnection = nil
    }

    // MARK: - Connection management

    /// New status selectors were added in build 2. Probe with the original,
    /// build-1-safe selector once per connection before sending either one.
    /// A mismatch is never cached, so repairing the daemon recovers naturally.
    private func requireCurrentHelperVersion() async throws {
        while true {
            let candidate = try activeConnection()
            if statusProtocolVerifiedConnection === candidate { return }

            let expected = SomnusConstants.version()
            let found = try await helperVersion()
            guard found == expected else {
                throw SomnusError.helperVersionMismatch(expected: expected, found: found)
            }

            // The actor is re-entrant while the XPC reply is awaited. Never
            // let a late reply from connection A mark replacement B verified.
            guard connection === candidate else { continue }
            statusProtocolVerifiedConnection = candidate
            return
        }
    }

    private struct Proxy {
        let connection: NSXPCConnection
        let remote: SomnusHelperProtocol
        let box: ContinuationBox
    }

    /// Returns a remote proxy whose error handler is wired to the same
    /// single-shot box as the reply block, so exactly one of them wins.
    private func proxy() throws -> Proxy {
        let connection = try activeConnection()
        let box = ContinuationBox()
        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            box.fail(SomnusError.from(error))
        }
        guard let helper = remote as? SomnusHelperProtocol else {
            throw SomnusError.connectionRefused
        }
        return Proxy(connection: connection, remote: helper, box: box)
    }

    private func activeConnection() throws -> NSXPCConnection {
        if let connection { return connection }

        let connection = NSXPCConnection(machServiceName: SomnusConstants.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = .somnusHelper

        // Authenticate the daemon. Set before resume, exactly once, and only
        // from a string that is well-formed by construction: a malformed
        // requirement raises an Objective-C exception, which is fatal in Swift.
        guard let requirement = SomnusCodeRequirement.helper else {
            // Unsigned / ad-hoc build: refuse rather than talk to an
            // unauthenticated root daemon.
            throw SomnusError.connectionRefused
        }
        connection.setCodeSigningRequirement(requirement)

        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { await self?.forgetConnection(connection) }
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { await self?.discard(connection) }
        }

        connection.resume()
        self.connection = connection
        return connection
    }

    /// A late callback from an old session must not erase a newer healthy one.
    private func forgetConnection(_ invalidated: NSXPCConnection) {
        guard connection === invalidated else { return }
        connection = nil
        statusProtocolVerifiedConnection = nil
    }

    /// A failed, interrupted or timed-out session is never reusable. This is
    /// what lets the next Control Center render make a genuinely new XPC
    /// attempt instead of returning the same cached failure forever.
    private func discard(_ failed: NSXPCConnection) {
        failed.invalidate()
        forgetConnection(failed)
    }
}

// MARK: - Single-shot continuation resumption

/// Three things are eligible to resume the awaiting continuation -
/// `remoteObjectProxyWithErrorHandler`'s handler, the reply block, and the
/// deadline armed by `arm(_:)`: and resuming a continuation twice traps. This
/// box lets the first one through and drops the rest. It is created *before*
/// the call is made, so the error handler can win the race.
///
/// One `NSLock` and one `finished` flag arbitrate all three; there is no
/// ordering in which two of them can both observe `finished == false`.
final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var pendingFailure: Error?
    private var onFailure: (@Sendable (Error) -> Void)?
    private var deadline: DispatchWorkItem?

    /// Registers how to resume the awaiting continuation when the XPC error
    /// handler or the deadline wins the race.
    ///
    /// MUST be called from inside the continuation closure, before the remote
    /// call is made. The error handler can fire *before* this runs (the proxy
    /// is built first), so a failure recorded earlier is delivered here
    /// immediately rather than being dropped.
    func register(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        if let pending = pendingFailure {
            pendingFailure = nil
            lock.unlock()
            handler(pending)                 // `finished` was set by fail()
            return
        }
        guard !finished else { lock.unlock(); return }
        onFailure = handler
        lock.unlock()
    }

    /// Arms the deadline. If nothing else has resolved the call within
    /// `seconds`, it fails as `connectionRefused`: the same case
    /// `SomnusError.from` already assigns to every "could not talk to somnusd"
    /// condition. A daemon that accepted the connection and then stopped
    /// answering is exactly that, and it is the ONLY thing standing between a
    /// wedged daemon and a caller that awaits forever.
    ///
    /// MUST be called after `register(_:)`, from inside the continuation
    /// closure: `register` is what installs the resumption path this uses.
    /// Arming when the call has already been resolved is a no-op.
    func arm(_ seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.fail(SomnusError.connectionRefused)
        }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        deadline = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds,
                                                       execute: item)
    }

    /// Called from the XPC error handler and from the deadline, possibly before
    /// the continuation closure has even run.
    func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        cancelDeadlineLocked()
        if let handler = onFailure {
            onFailure = nil
            lock.unlock()
            handler(error)
        } else {
            pendingFailure = error           // register() will deliver it
            lock.unlock()
        }
    }

    func resume<T>(with result: Result<T, Error>,
                   into continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        onFailure = nil
        cancelDeadlineLocked()
        lock.unlock()
        continuation.resume(with: result)
    }

    /// Caller holds `lock`. `DispatchWorkItem.cancel()` never runs or waits for
    /// the block, so cancelling under the lock cannot deadlock against a
    /// deadline block that is already blocked entering `fail`; that block will
    /// simply observe `finished == true` and drop.
    private func cancelDeadlineLocked() {
        deadline?.cancel()
        deadline = nil
    }
}
