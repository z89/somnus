//  PowerEngine.swift
//  somnus: power engine.
//
//  Responsibilities:
//    * watch IOPSNotificationCreateRunLoopSource for power-source changes and
//      somnusd's confirmed-write signal for Stay Awake changes, backed by a
//      low-frequency periodic re-evaluation and a wake observer,
//    * publish `PowerFacts` (battery, AC, charging, lid, hibernatemode, SleepDisabled),
//    * hold the idle assertions (WakeAssertion.swift) for exactly as long as
//      Stay Awake is on, so "stay awake" also means the display stays on;
//      `SleepDisabled` alone leaves `displaysleep` in charge of the panel,
//    * run the two-stage safety net (warn at 20%, act at 10%) with a latch so a
//      threshold crossing fires exactly once,
//    * run AC-aware mode (opt-in) on power-source transitions,
//    * publish the `pmset -g assertions` inspector.
//
//  Every decision is taken by the pure `SafetyNetPolicy` (PowerPolicy.swift) and
//  every effect goes through `PowerEnvironment` (PowerEnvironment.swift), so the
//  whole engine is testable without ever touching real power state. In
//  particular `pmset sleepnow` is reached ONLY through
//  `PowerEnvironment.requestSleepNow`, which is a stub closure in every test.

import AppKit
import Foundation
import Observation
import os
import SomnusKit

@MainActor
@Observable
public final class PowerEngine: PowerEngineObserving {

    /// The one engine the app uses. Creating it installs the power-source
    /// run-loop source, so the app must touch this once at launch or the
    /// safety net never arms.
    public static let shared: PowerEngine = {
        let engine = PowerEngine(environment: .live)
        engine.start()
        return engine
    }()

    // MARK: - PowerEngineObserving (stable contract)

    /// Latest snapshot. `nil` until the first successful sample.
    public private(set) var facts: PowerFacts?

    /// What else is holding the Mac awake. Refreshed by `refresh()` only -
    /// never on the power-source callback, which fires very often.
    public private(set) var assertions: [SleepAssertion] = []

    public var acAwareModeEnabled: Bool {
        get { preferences.acAwareModeEnabled }
        set {
            guard newValue != preferences.acAwareModeEnabled else { return }
            preferences.acAwareModeEnabled = newValue
            if !newValue { clearACAwareFailure() }
            persistPreferences()
        }
    }

    /// Battery percentage at or below which somnus warns. Default 20.
    public var warnThreshold: Int {
        get { preferences.warnThreshold }
        set {
            let clamped = preferences.clamping(warn: newValue, act: preferences.actThreshold)
            guard clamped != preferences else { return }
            preferences = clamped
            persistPreferences()
        }
    }

    /// Battery percentage at or below which somnus turns Stay Awake off.
    /// Default 10, deliberately conservative: it leaves room for a clean sleep.
    public var actThreshold: Int {
        get { preferences.actThreshold }
        set {
            let clamped = preferences.clamping(warn: preferences.warnThreshold, act: newValue)
            guard clamped != preferences else { return }
            preferences = clamped
            persistPreferences()
        }
    }

    /// Full refresh: power source, lid, `pmset -g`, Stay Awake, assertions, then
    /// the safety net. Drives the prefs UI; also safe to call on wake.
    public func refresh() async {
        await evaluate(includeAssertions: true)
    }

    // MARK: - Diagnostics

    /// `false` when the hibernatemode preflight refused to arm. When this is
    /// false the safety net takes no action at all: show the reason.
    public private(set) var safetyNetArmed = true

    /// Human-readable reason the safety net is not armed, or `nil` when it is.
    public private(set) var safetyNetDisarmedReason: String?

    /// Where the two-stage latch currently sits. Exposed for the prefs UI and
    /// for diagnostics; the latch is what makes a crossing fire exactly once.
    public var safetyNetStage: SafetyNetPolicy.Stage { policy.stage }

    /// True only when a confirmed low-battery safety action is waiting for the
    /// battery to recover far enough to restore the user's prior ON state.
    public var safetyRestorePending: Bool { policy.safetyRestorePending }

    /// `false` when the last pass could read Stay Awake from neither the helper
    /// nor `pmset -g`, so `facts.sleepDisabled` is a placeholder rather than a
    /// reading. Anything that must fail closed checks this before trusting it.
    public private(set) var stayAwakeIsKnown = false
    public private(set) var idleAssertionsHealthy = true

    /// `true` once `start()` has installed the watches, `false` after `stop()`.
    ///
    /// This is **not** the same question as "is the safety net healthy". The
    /// engine has two independent sensors: the IOKit power-source notification
    /// and the periodic backstop: and `start()` always installs the backstop,
    /// so `isMonitoring` can be true while the primary sensor is dead. Read
    /// `monitoringDegradedReason` for that.
    public private(set) var isMonitoring = false

    /// `nil` when the IOKit power-source notification is installed and the
    /// engine is sampling on every real power-source change. Non-`nil` when
    /// that registration failed and the engine is running on the periodic
    /// backstop alone: still watching, but coarsely, and up to
    /// `degradedBackstopInterval` late.
    ///
    /// This is a *user-facing* string: the safety net is the reason somnus
    /// exists, so "it is watching, but not the way it should be" has to be
    /// visible in Preferences and as a one-shot notification.
    public private(set) var monitoringDegradedReason: String?
    private var powerSourceReadFailureReason: String?

    /// Why the last AC-aware write failed, or `nil` when the most recent one
    /// succeeded (or none has been attempted). Almost always "the helper is not
    /// installed or not approved": the same cause the System Integration section of the
    /// preferences window already reports, which is exactly why this needs to
    /// be shown next to the AC-aware toggle: today the feature simply does
    /// nothing and never says why.
    public private(set) var acAwareLastFailureReason: String?

    /// When the engine last finished sampling the machine and running the
    /// policy. Stale means the net has stopped evaluating, which is the failure
    /// mode no policy fix can cover: so this is the one value worth showing
    /// even when everything is fine.
    public private(set) var lastEvaluation: Date?

    /// Everything above in one observation-friendly value. Reading this inside a
    /// SwiftUI `body` registers a dependency on each underlying stored property,
    /// because `@Observable` instruments the property accesses this performs.
    public var health: PowerEngineHealth {
        PowerEngineHealth(isMonitoring: isMonitoring,
                          monitoringDegradedReason: monitoringDegradedReason
                            ?? powerSourceReadFailureReason,
                          safetyNetArmed: safetyNetArmed,
                          safetyNetDisarmedReason: safetyNetDisarmedReason,
                          safetyRestorePending: safetyRestorePending,
                          idleAssertionsHealthy: idleAssertionsHealthy,
                          acAwareModeEnabled: acAwareModeEnabled,
                          acAwareLastFailureReason: acAwareLastFailureReason,
                          lastEvaluation: lastEvaluation)
    }

    // MARK: - Internals

    private let environment: PowerEnvironment
    private var policy: SafetyNetPolicy
    private var preferences: PowerPreferences {
        didSet { policy.preferences = preferences }
    }

    private var runLoopSource: CFRunLoopSource?
    private var callbackContext: UnsafeMutableRawPointer?

    /// Initial refresh, periodic backstop, wake re-evaluation and act retry.
    /// Every retained task is torn down by `stop()`.
    private var initialRefreshTask: Task<Void, Never>?
    private var backstopTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?
    private var cancelStayAwakeObservation: (() -> Void)?
    private var cancelManualOffObservation: (() -> Void)?
    private var stayAwakeChangeTask: Task<Void, Never>?
    private var stayAwakeChangePending = false
    private var stayAwakeChangeGeneration = 0

    /// The last `SleepDisabled` observed by either a full evaluation or a
    /// confirmed-change event. It is diagnostic only: every event still asks
    /// Control Center to reload and every evaluation still reads live truth.
    private var lastObservedSleepDisabled: Bool?

    /// Set the first time an AC-aware write fails, cleared when one succeeds,
    /// so a user cycling the MagSafe plug does not get the same complaint on
    /// every unplug.
    private var acAwareFailureAnnounced = false

    /// Evaluations are serialised: the IOKit notification can fire many times a
    /// second, and two overlapping evaluations could each decide to act.
    private var evaluationInFlight = false
    private var evaluationRequested = false
    private var requestedAssertions = false
    private var evaluationWaiters: [CheckedContinuation<Void, Never>] = []

    private static let log = Logger(subsystem: SomnusConstants.appBundleID, category: "power")

    public init(environment: PowerEnvironment) {
        self.environment = environment
        let loaded = environment.loadPreferences()
        self.preferences = loaded
        // Restoration ownership is deliberately process-lifetime only. A new
        // guardian cannot distinguish an old safety OFF from a newer user OFF.
        self.policy = SafetyNetPolicy(preferences: loaded)
    }

    deinit {
        // `stop()` is @MainActor and deinit is not; the singleton never
        // deallocates, and a test-owned engine that was never started has
        // nothing to tear down: `start()` is what creates the run-loop source,
        // the backstop task and the wake observer, so an engine that never
        // started owns none of them. Anything else must call stop() explicitly.
    }

    // MARK: - Monitoring lifecycle

    /// How often the backstop re-evaluates while the IOKit power-source
    /// notification is healthy.
    ///
    /// **Why 5 minutes.** On the normal path this timer is not how the safety
    /// net works: a real discharge changes the reported percentage constantly
    /// and IOKit posts a notification for each change, so the net has already
    /// evaluated many times before the backstop ever fires. The timer exists for
    /// the case where that stream is silent (registration failed, the source was
    /// somehow removed, the process was suspended and resumed), and there the
    /// only thing that matters is catching the 20% and 10% thresholds before 0%.
    /// This is a laptop, so the cost is real and one-sided: each tick spawns
    /// `pmset -g`, reads IOKit, and makes one XPC round trip to somnusd. A tight
    /// poll would burn battery to protect the battery. 5 minutes costs 288
    /// evaluations a day: negligible against a discharge that takes hours to
    /// cross 10 percentage points, which leaves several samples between warn and
    /// act even in the worst case.
    ///
    /// Nothing here polls faster than before on the normal path: IOKit events,
    /// confirmed helper writes and explicit refreshes drive ordinary updates.
    static let backstopInterval: TimeInterval = 300

    /// Deliberately huge (20% of the interval) so the OS coalesces this wake-up
    /// with whatever else it was already going to wake for. A backstop has no
    /// use for punctuality.
    static let backstopTolerance: TimeInterval = 60

    /// The interval used when the IOKit registration failed and this timer is
    /// the *only* sensor. One minute is chosen against the thing that actually
    /// matters (the battery cannot fall from above 10% to 0% in a minute), and
    /// it only ever runs in a failure state that also tries to repair itself on
    /// every tick.
    static let degradedBackstopInterval: TimeInterval = 60
    static let degradedBackstopTolerance: TimeInterval = 5

    private static let degradedReason = """
        somnus could not register for power-source notifications, so it is not \
        being told when the battery changes. The safety net has fallen back to \
        checking every minute and may act up to a minute late. Quitting and \
        reopening somnus usually fixes this.
        """

    private static let powerSourceReadFailure = """
        somnus could not read a trustworthy battery or power-source value. The safety net is \
        temporarily disarmed and will retry every minute. Turn Stay Awake off until the reading \
        recovers.
        """

    /// Installs the power-source run-loop source, the wake observer and the
    /// periodic backstop. Idempotent.
    ///
    /// The run-loop source failing is **not** fatal any more. It used to return
    /// early, leaving an engine that never evaluated again and never said so -
    /// which can leave the Mac awake without battery protection. The other two
    /// watches are installed regardless, `monitoringDegradedReason` records what
    /// happened, and the backstop retries the registration on every tick.
    public func start() {
        guard !isMonitoring else { return }

        environment.prepareNotifications()

        let installed = installPowerSourceNotification()
        installWakeObserver()
        startBackstop()
        isMonitoring = true
        startStayAwakeObservation()
        startManualOffObservation()

        if installed {
            Self.log.notice("Power monitoring started.")
        } else {
            environment.notify(.monitoringDegraded(reason: Self.degradedReason))
            Self.log.fault("Power monitoring started WITHOUT power-source notifications; running on the periodic backstop alone.")
        }

        initialRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            self.initialRefreshTask = nil
        }
    }

    /// Removes the run-loop source, the wake observer and both tasks. Idempotent.
    public func stop() {
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        backstopTask?.cancel()
        backstopTask = nil
        retryTask?.cancel()
        retryTask = nil
        cancelStayAwakeObservation?()
        cancelStayAwakeObservation = nil
        cancelManualOffObservation?()
        cancelManualOffObservation = nil
        stayAwakeChangeGeneration += 1
        stayAwakeChangeTask?.cancel()
        stayAwakeChangeTask = nil
        stayAwakeChangePending = false
        lastObservedSleepDisabled = nil

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let context = callbackContext {
            Unmanaged<PowerEngine>.fromOpaque(context).release()
        }
        callbackContext = nil
        monitoringDegradedReason = nil
        isMonitoring = false

        // The engine is no longer watching, so it must not keep holding the
        // machine awake. Process exit would drop these anyway; `stop()` without
        // a matching exit (uninstall, teardown in a host app) would not.
        idleAssertionsHealthy = environment.setIdleAssertions(false)
    }

    /// Called from the IOKit run-loop callback, already hopped onto the main
    /// actor. Cheap path: no `pmset -g assertions`.
    func powerSourceDidChange() {
        guard isMonitoring else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isMonitoring else { return }
            await self.evaluate(includeAssertions: false)
        }
    }

    /// Called on `NSWorkspace.didWakeNotification`. The machine may have been
    /// asleep for hours and the charge is whatever it is now, so the very first
    /// thing to do is take a fresh sample: every input is re-read, nothing is
    /// carried over. A wake also retries the Control Center refresh: the system
    /// may have suspended the widget host before an earlier reload was serviced.
    /// Cheap path: assertions are a preferences-window concern.
    func systemDidWake() {
        guard isMonitoring else { return }
        Self.log.notice("System woke; re-evaluating the safety net.")
        Task { @MainActor [weak self] in
            guard let self, self.isMonitoring else { return }
            await self.evaluate(includeAssertions: false)
            self.environment.reloadControlCenter()
        }
    }

    /// Registers for IOKit power-source notifications. Returns `false` and sets
    /// `monitoringDegradedReason` if that is not possible.
    @discardableResult
    private func installPowerSourceNotification() -> Bool {
        guard runLoopSource == nil else { return true }

        // Retained: the callback dereferences this pointer from the run loop,
        // so the engine must outlive the source. Released in `stop()`.
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let source = environment.makeRunLoopSource(context) else {
            Unmanaged<PowerEngine>.fromOpaque(context).release()
            monitoringDegradedReason = Self.degradedReason
            Self.log.error("Could not create the power-source run-loop source; the safety net is running on the backstop only.")
            return false
        }
        callbackContext = context
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        if monitoringDegradedReason != nil {
            Self.log.notice("Power-source notifications recovered.")
        }
        monitoringDegradedReason = nil
        return true
    }

    /// `Somnus.app` is not sandboxed, so `NSWorkspace.notificationCenter` is
    /// available. The block is delivered on the main queue, which is the main
    /// actor's executor; `SWIFT_VERSION` is 5.0 so the compiler will not prove
    /// that, and `assumeIsolated` states it and traps loudly if it is ever
    /// violated rather than racing the engine's state.
    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemDidWake()
                }
            }
    }

    /// The periodic backstop. One task, one evaluation at a time: it awaits each
    /// evaluation before sleeping again, and `evaluate` itself coalesces through
    /// `evaluationInFlight`, so a tick that lands on top of an in-flight
    /// evaluation is folded into it instead of stacking a second one.
    private func startBackstop() {
        backstopTask?.cancel()
        backstopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let degraded = self.monitoringDegradedReason != nil
                    || self.powerSourceReadFailureReason != nil
                let interval = degraded ? Self.degradedBackstopInterval : Self.backstopInterval
                let tolerance = degraded ? Self.degradedBackstopTolerance : Self.backstopTolerance

                // `ContinuousClock` keeps counting while the Mac is asleep, so a
                // long sleep expires this immediately on wake rather than owing
                // the machine five quiet minutes.
                do {
                    try await Task.sleep(for: .seconds(interval), tolerance: .seconds(tolerance))
                } catch {
                    return  // cancelled by stop()
                }
                guard !Task.isCancelled else { return }

                // Self-heal: a registration that failed at launch gets another
                // attempt every tick, so a transient IOKit failure costs a
                // minute of coarse sampling rather than the whole session.
                if self.monitoringDegradedReason != nil
                    || self.powerSourceReadFailureReason != nil {
                    self.installPowerSourceNotification()
                }

                await self.evaluate(includeAssertions: false)
            }
        }
    }

    /// Registers for the payload-free Darwin signal somnusd posts after every
    /// confirmed write. The signal is only an edge trigger: the handler reads
    /// `SleepDisabled` again, so coalesced or duplicated notifications cannot
    /// turn into cached state.
    private func startStayAwakeObservation() {
        cancelStayAwakeObservation?()
        cancelStayAwakeObservation = environment.observeStayAwakeChanges { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring else { return }
                self.enqueueStayAwakeChange()
            }
        }
    }

    private func startManualOffObservation() {
        cancelManualOffObservation?()
        cancelManualOffObservation = environment.observeManualOffIntents { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring else { return }
                self.handleManualOffIntent()
            }
        }
    }

    func handleManualOffIntent() {
        let wasPending = policy.safetyRestorePending
        policy.cancelSafetyRestore()
        if wasPending {
            Self.log.notice("An explicit Stay Awake OFF cancelled automatic restoration.")
        }
    }

    /// Darwin notifications are intentionally unauthenticated hints: any local
    /// process can post the public name. Process the leading edge immediately,
    /// coalesce a burst to its final live value, and throttle trailing passes so
    /// a notification flood cannot make the app spawn unbounded `pmset` reads.
    private func enqueueStayAwakeChange() {
        stayAwakeChangePending = true
        guard stayAwakeChangeTask == nil else { return }

        stayAwakeChangeGeneration += 1
        let generation = stayAwakeChangeGeneration
        stayAwakeChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.stayAwakeChangeGeneration == generation {
                    self.stayAwakeChangeTask = nil
                }
            }

            while self.isMonitoring, !Task.isCancelled {
                self.stayAwakeChangePending = false
                await self.handleStayAwakeChange()
                guard self.stayAwakeChangePending else { return }
                do {
                    try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    /// Handles one confirmed-change edge. Control Center is asked to re-read
    /// immediately; assertion reconciliation uses the cheap IORegistry value;
    /// and the full serialized evaluation follows to update the observable
    /// snapshot and run the low-battery policy against the new truth.
    ///
    /// An unreadable fast value is UNKNOWN, not `false`: assertions remain as
    /// they are until the full helper/`pmset` read completes.
    func handleStayAwakeChange() async {
        environment.reloadControlCenter()

        if let sleepDisabled = environment.readSleepDisabledFast() {
            let previouslyObserved = lastObservedSleepDisabled
            if previouslyObserved == true,
               !sleepDisabled,
               policy.safetyRestorePending {
                policy.cancelSafetyRestore()
                Self.log.notice("An outside Stay Awake OFF superseded the pending safety restoration.")
            }
            idleAssertionsHealthy = environment.setIdleAssertions(sleepDisabled)
            if lastObservedSleepDisabled != sleepDisabled {
                Self.log.notice("Confirmed Stay Awake change to \(sleepDisabled ? "ON" : "OFF", privacy: .public); re-evaluating.")
            }
            lastObservedSleepDisabled = sleepDisabled
        }

        await evaluate(includeAssertions: false)
    }

    /// After a failed safety write the policy holds retry for `retryInterval`. That
    /// is a back-off, not a schedule: nothing re-armed a wake-up, so the retry
    /// only ever happened if IOKit *happened* to fire again: on a machine whose
    /// Stay Awake write is failing, at 10% battery. This arms the clock the
    /// back-off assumes.
    private func scheduleActRetry() {
        let delay = policy.retryInterval + 1
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay), tolerance: .seconds(1))
            } catch {
                return  // cancelled by stop()
            }
            guard let self, !Task.isCancelled else { return }
            Self.log.notice("Write back-off elapsed; retrying the safety policy.")
            await self.evaluate(includeAssertions: false)
        }
    }

    // MARK: - The evaluation cycle

    /// Serialises evaluation while preserving every caller's contract:
    /// `refresh()` does not return until its requested pass has completed. Quit
    /// and uninstall depend on that before making a decision from `facts`.
    func evaluate(includeAssertions: Bool) async {
        guard !evaluationInFlight else {
            evaluationRequested = true
            requestedAssertions = requestedAssertions || includeAssertions
            await withCheckedContinuation { continuation in
                evaluationWaiters.append(continuation)
            }
            return
        }

        evaluationInFlight = true
        var wantsAssertions = includeAssertions
        defer {
            evaluationInFlight = false
            let waiters = evaluationWaiters
            evaluationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        while true {
            evaluationRequested = false
            requestedAssertions = false
            await evaluatePass(includeAssertions: wantsAssertions)
            guard evaluationRequested else { break }
            wantsAssertions = requestedAssertions
        }
    }

    private func evaluatePass(includeAssertions: Bool) async {
        let sample = await environment.readPowerSource()
        let previouslyUnreliable = powerSourceReadFailureReason != nil
        powerSourceReadFailureReason = sample.isReliable ? nil : Self.powerSourceReadFailure
        if !sample.isReliable, !previouslyUnreliable {
            environment.notify(.monitoringDegraded(reason: Self.powerSourceReadFailure))
            Self.log.fault("Battery/power-source read is unreliable; safety policy is disarmed until it recovers.")
        }
        // Read at the moment of the decision, never cached from an earlier
        // notification.
        let lid = await environment.readLidClosed()
        let settings = await environment.readSleepSettings()

        // State is never cached: Stay Awake comes from somnusd -> `pmset -g`.
        // If the helper is unreachable we fall back to this process's own
        // read-only `pmset -g`, which is the same source of truth: the safety
        // net must not go blind just because the daemon is down.
        let stayAwake: Bool
        do {
            stayAwake = try await environment.readStayAwake()
            stayAwakeIsKnown = true
        } catch {
            stayAwake = settings.sleepDisabled
            stayAwakeIsKnown = settings.sleepDisabledIsKnown
            Self.log.error("Stay Awake read failed (\(error.localizedDescription, privacy: .public)); using pmset -g SleepDisabled = \(settings.sleepDisabled, privacy: .public).")
        }

        facts = PowerFacts(batteryPercent: sample.batteryPercent,
                           isOnAC: sample.isOnAC,
                           isCharging: sample.isCharging,
                           // PowerFacts.lidClosed is non-optional; unknown is
                           // reported as "not closed", which is the branch that
                           // never sleeps the Mac.
                           lidClosed: lid == true,
                           hibernateMode: settings.hibernateMode,
                           sleepDisabled: stayAwake)

        if includeAssertions {
            assertions = await environment.readAssertions()
        }

        // Reconcile the idle assertions to the state we just OBSERVED, not to
        // what we last wrote. Stay Awake can be turned on without this engine
        // ever being asked: the Control Center widget and the CLI both talk to
        // somnusd directly: and this pass is the only place that notices. Any
        // action the policy returns below re-reconciles from the confirmed
        // value in `perform`, so a safety-net act cannot leave them held.
        idleAssertionsHealthy = environment.setIdleAssertions(stayAwake)
        lastObservedSleepDisabled = stayAwake

        let input = SafetyNetInput(batteryPercent: sample.batteryPercent,
                                   batteryPresent: sample.isReliable && sample.batteryPresent,
                                   isOnAC: sample.isOnAC,
                                   isCharging: sample.isCharging,
                                   stayAwakeOn: stayAwake,
                                   lidClosed: lid,
                                   hibernateMode: settings.hibernateMode,
                                   powerSourceReliable: sample.isReliable)

        let now = environment.now()
        let actions = policy.evaluate(input, now: now)
        lastEvaluation = now
        safetyNetArmed = policy.isArmed && sample.isReliable
        if !sample.isReliable {
            safetyNetDisarmedReason = Self.powerSourceReadFailure
        } else {
            safetyNetDisarmedReason = policy.isArmed
                ? nil
                : PowerNotice.preflightRefused(hibernateMode: settings.hibernateMode).body
        }

        await perform(actions, percent: sample.batteryPercent)
    }

    /// Executes the policy's actions **in order**, awaiting each one. Order is
    /// load-bearing: Stay Awake must be off, and confirmed off by somnusd,
    /// before the Mac is asked to sleep.
    private func perform(_ actions: [PowerAction], percent: Int) async {
        for action in actions {
            switch action {
            case let .setStayAwake(on, reason):
                var writeError: Error?
                do {
                    let origin: StayAwakeWriteOrigin = reason == .safetyNet
                        ? .safetyNet
                        : .userOrAutomation
                    try await environment.setStayAwake(on, origin)
                } catch {
                    writeError = error
                }

                // Do not trust either an exit status or an XPC reply as the
                // postcondition. A fresh local `pmset -g` read is independent of
                // the helper connection and preserves an explicit unknown state.
                let confirmation = await environment.readSleepSettings()
                if confirmation.sleepDisabledIsKnown,
                   confirmation.sleepDisabled == on {
                    policy.recordStayAwakeWrite(on, reason: reason)
                    publishConfirmedStayAwake(on)
                    // Confirmed truth, so the assertions follow it immediately
                    // rather than waiting for the next pass. Releasing on the
                    // safety net's `false` is what lets the Mac fall back to
                    // its normal idle timer at 10%.
                    idleAssertionsHealthy = environment.setIdleAssertions(on)
                    // Our own write is not an outside change; record it so the
                    // confirmed-change event does not look like an unexplained
                    // transition when it arrives.
                    lastObservedSleepDisabled = on
                    // The widget renders whatever it last read. An engine-driven
                    // flip that does not ask it to re-read leaves the toggle
                    // showing a state the machine is no longer in.
                    environment.reloadControlCenter()
                    Self.log.notice("Set Stay Awake \(on ? "ON" : "OFF", privacy: .public) (\(String(describing: reason), privacy: .public)).")
                    if reason == .acAware { clearACAwareFailure() }
                    if reason == .safetyNet || reason == .safetyRestore {
                        retryTask?.cancel()
                        retryTask = nil
                    }
                    if writeError != nil {
                        Self.log.notice("The Stay Awake write reported an error but independent read-back confirmed the requested state; remaining actions still hold.")
                    }
                    continue
                }

                let failure = writeError ?? SomnusError.pmsetFailed(
                    status: -1,
                    stderr: confirmation.sleepDisabledIsKnown
                        ? "SleepDisabled read back as \(confirmation.sleepDisabled ? 1 : 0)"
                        : "SleepDisabled could not be read back after the write")
                Self.log.fault("Could not confirm Stay Awake \(on ? "ON" : "OFF", privacy: .public): \(failure.localizedDescription, privacy: .public)")

                switch reason {
                case .acAware:
                    recordACAwareFailure(failure, requested: on)
                    continue
                case .safetyRestore:
                    policy.recordRestoreFailure(now: environment.now())
                    environment.notify(.safetyNetRestoreFailed(
                        percent: percent,
                        reason: failure.localizedDescription))
                    scheduleActRetry()
                    return
                case .safetyNet:
                    break
                }

                // The safety action is not confirmed. Roll the latch back,
                // schedule a bounded retry, tell the truth, and abandon the
                // success notice and sleep request that follow this action.
                policy.recordActFailure(now: environment.now())
                scheduleActRetry()
                environment.notify(.safetyNetFailed(percent: percent,
                                                    reason: failure.localizedDescription))
                return

            case let .notify(notice):
                Self.log.notice("Notify: \(notice.body, privacy: .public)")
                environment.notify(notice)

            case .requestSleepNow:
                Self.log.notice("Requesting immediate system sleep (lid closed, battery \(percent, privacy: .public)%).")
                let ok = await environment.requestSleepNow()
                if !ok {
                    Self.log.fault("The sleep request failed. The Mac is still awake on battery.")
                    environment.notify(.sleepRequestFailed(percent: percent))
                }
            }
        }
    }

    /// Keep the observable snapshot aligned with a write that was independently
    /// read back. Without this, a safety-net write leaves `facts` saying ON until
    /// another full sample, so the heartbeat cannot detect the change and retry
    /// a Control Center refresh that macOS dropped.
    private func publishConfirmedStayAwake(_ on: Bool) {
        stayAwakeIsKnown = true
        guard let facts else { return }
        self.facts = PowerFacts(batteryPercent: facts.batteryPercent,
                                isOnAC: facts.isOnAC,
                                isCharging: facts.isCharging,
                                lidClosed: facts.lidClosed,
                                hibernateMode: facts.hibernateMode,
                                sleepDisabled: on)
    }

    // MARK: - AC-aware failure reporting

    /// Records an AC-aware write failure. Loud once, quiet afterwards: the
    /// cause is a standing condition (no helper), so repeating it on every
    /// plug/unplug would be noise, not information.
    ///
    /// The user-visible half arrives via `PowerNotice.acAwareFailed`, which is
    /// deliberately `isCritical == false`: AC-aware mode is a convenience, not
    /// the data-loss path. Announced once per episode via
    /// `acAwareFailureAnnounced`, cleared by the next successful AC-aware write,
    /// so plug/unplug cycling cannot nag.
    private func recordACAwareFailure(_ error: Error, requested on: Bool) {
        acAwareLastFailureReason = error.localizedDescription

        guard !acAwareFailureAnnounced else {
            Self.log.info("AC-aware mode still cannot set Stay Awake \(on ? "ON" : "OFF", privacy: .public); already reported.")
            return
        }
        acAwareFailureAnnounced = true
        // Without this the toggle promises "Turns Stay Awake on when you plug
        // in" and silently does nothing.
        environment.notify(.acAwareFailed(turningOn: on, reason: error.localizedDescription))
        Self.log.fault("AC-aware mode is not working: Stay Awake could not be set \(on ? "ON" : "OFF", privacy: .public). \(error.localizedDescription, privacy: .public)")
    }

    /// An AC-aware write landed, so the episode is over and the next failure is
    /// allowed to report itself again.
    private func clearACAwareFailure() {
        acAwareLastFailureReason = nil
        acAwareFailureAnnounced = false
    }

    private func persistPreferences() {
        policy.preferences = preferences
        environment.savePreferences(preferences)
    }

}

// MARK: - Engine health

/// One value carrying everything the engine knows about **itself**: as opposed
/// to `PowerFacts`, which is what it knows about the machine.
///
/// This exists because the stable `PowerEngineObserving` protocol has no room
/// for it and cannot be changed. `PowerEngineBridge` exposes the concrete
/// engine's health to Preferences without spreading that concrete type through
/// the rest of the app.
public struct PowerEngineHealth: Equatable, Sendable {

    /// `start()` has installed the watches. Not a health check on its own.
    public var isMonitoring: Bool

    /// Non-`nil` means the engine is watching coarsely, on the backstop alone.
    public var monitoringDegradedReason: String?

    /// `false` means the safety net will take no action at all.
    public var safetyNetArmed: Bool

    /// Why it is not armed. The only place this reason exists.
    public var safetyNetDisarmedReason: String?

    /// A confirmed safety-net OFF is waiting for charge recovery. This is
    /// provenance of an automatic action, not a cached power-state value.
    public var safetyRestorePending: Bool

    /// False only when Stay Awake is on and the display assertion failed.
    public var idleAssertionsHealthy: Bool

    public var acAwareModeEnabled: Bool

    /// Why the last AC-aware write failed. Non-`nil` means the AC-aware toggle
    /// is on and doing nothing.
    public var acAwareLastFailureReason: String?

    /// When the engine last sampled. `nil` means it never has.
    public var lastEvaluation: Date?

    /// `true` when everything the engine can check about itself is fine, so a
    /// UI can show one line in the common case and expand only when it is not.
    public var isHealthy: Bool {
        isMonitoring
            && monitoringDegradedReason == nil
            && safetyNetArmed
            && idleAssertionsHealthy
            && acAwareLastFailureReason == nil
            && lastEvaluation != nil
    }

    public init(isMonitoring: Bool,
                monitoringDegradedReason: String?,
                safetyNetArmed: Bool,
                safetyNetDisarmedReason: String?,
                safetyRestorePending: Bool,
                idleAssertionsHealthy: Bool,
                acAwareModeEnabled: Bool,
                acAwareLastFailureReason: String?,
                lastEvaluation: Date?) {
        self.isMonitoring = isMonitoring
        self.monitoringDegradedReason = monitoringDegradedReason
        self.safetyNetArmed = safetyNetArmed
        self.safetyNetDisarmedReason = safetyNetDisarmedReason
        self.safetyRestorePending = safetyRestorePending
        self.idleAssertionsHealthy = idleAssertionsHealthy
        self.acAwareModeEnabled = acAwareModeEnabled
        self.acAwareLastFailureReason = acAwareLastFailureReason
        self.lastEvaluation = lastEvaluation
    }
}

// MARK: - The IOKit callback

/// `IOPowerSourceCallbackType` is a C function pointer, so this must be a global
/// function. `IOPSNotificationCreateRunLoopSource`'s source is added to the MAIN
/// run loop in `start()`, therefore this always runs on the main thread: but
/// SWIFT_VERSION is 5.0, so the compiler will not prove that. `assumeIsolated`
/// makes the assumption explicit and traps loudly if it is ever violated,
/// instead of silently racing the engine's state.
func somnusPowerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let engine = Unmanaged<PowerEngine>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        engine.powerSourceDidChange()
    }
}
