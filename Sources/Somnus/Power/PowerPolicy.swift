//  PowerPolicy.swift
//  somnus: power policy.
//
//  The whole safety net decision, as a pure value type. It performs no I/O, does
//  not know what a notification or `pmset` is, and is fully deterministic given
//  an input and a clock: which is what makes the 20%/10% behaviour, the
//  anti-flap latch, the lid branch and the hibernatemode preflight unit-testable
//  without touching the machine.

import Foundation

// MARK: - Preferences

/// User preferences, not power state. The "never cache state" rule is about
/// `SleepDisabled`/battery/lid: those are re-read from the system on every
/// evaluation and are never stored. These three values are the user's own
/// settings and are persisted so AC-aware mode survives a relaunch.
public struct PowerPreferences: Equatable, Sendable {
    public var acAwareModeEnabled: Bool
    public var warnThreshold: Int
    public var actThreshold: Int

    public init(acAwareModeEnabled: Bool, warnThreshold: Int, actThreshold: Int) {
        self.acAwareModeEnabled = acAwareModeEnabled
        self.warnThreshold = warnThreshold
        self.actThreshold = actThreshold
    }

    /// 20 / 10. Not 20/5: 10% is deliberately conservative, so the Mac still
    /// has charge left to sleep cleanly after a late or retried write.
    public static let defaults = PowerPreferences(acAwareModeEnabled: false,
                                                  warnThreshold: 20,
                                                  actThreshold: 10)

    /// Bounds `clamped` enforces. The steppers use the same numbers, so the UI
    /// never offers a value the model would snap back.
    public static let actRange = 5...50
    public static let warnCeiling = 90

    /// Keeps the pair sane however the UI drives it: act in `actRange`, warn
    /// strictly above act and at most `warnCeiling`.
    public static func clamped(warn: Int, act: Int, acAware: Bool? = nil) -> PowerPreferences {
        let clampedAct = min(max(act, actRange.lowerBound), actRange.upperBound)
        let clampedWarn = min(max(warn, clampedAct + 1), warnCeiling)
        return PowerPreferences(acAwareModeEnabled: acAware ?? defaults.acAwareModeEnabled,
                                warnThreshold: clampedWarn,
                                actThreshold: clampedAct)
    }

    /// Same clamp, preserving this value's `acAwareModeEnabled`.
    public func clamping(warn: Int, act: Int) -> PowerPreferences {
        PowerPreferences.clamped(warn: warn, act: act, acAware: acAwareModeEnabled)
    }
}

// MARK: - Input

/// One complete observation of the machine. Assembled fresh on every evaluation;
/// nothing here is ever carried over from a previous notification.
public struct SafetyNetInput: Equatable, Sendable {
    public var batteryPercent: Int
    /// `false` on a Mac with no battery: the safety net must never fire there.
    public var batteryPresent: Bool
    public var isOnAC: Bool
    public var isCharging: Bool
    /// `SleepDisabled`, i.e. somnus's Stay Awake. The safety net only counteracts
    /// somnus's own hazard: with Stay Awake off, the Mac already sleeps normally.
    public var stayAwakeOn: Bool
    /// `AppleClamshellState`. **`nil` means unknown** (lidless Mac, property
    /// absent) and is never treated as closed: unknown takes the branch that
    /// does not sleep the machine.
    public var lidClosed: Bool?
    public var hibernateMode: Int
    /// `false` when the IOKit power-source read failed. `isOnAC` is then a
    /// placeholder, so it must never count as a plug or unplug.
    public var powerSourceReliable: Bool

    public init(batteryPercent: Int,
                batteryPresent: Bool,
                isOnAC: Bool,
                isCharging: Bool,
                stayAwakeOn: Bool,
                lidClosed: Bool?,
                hibernateMode: Int,
                powerSourceReliable: Bool = true) {
        self.powerSourceReliable = powerSourceReliable
        self.batteryPercent = batteryPercent
        self.batteryPresent = batteryPresent
        self.isOnAC = isOnAC
        self.isCharging = isCharging
        self.stayAwakeOn = stayAwakeOn
        self.lidClosed = lidClosed
        self.hibernateMode = hibernateMode
    }
}

// MARK: - Output

public enum PowerNotice: Equatable, Sendable {
    case batteryWarning(percent: Int, actThreshold: Int)
    case safetyNetActed(percent: Int, requestedSleep: Bool)
    case safetyNetRestored(percent: Int)
    case safetyNetFailed(percent: Int, reason: String)
    case safetyNetRestoreFailed(percent: Int, reason: String)
    case sleepRequestFailed(percent: Int)
    case preflightRefused(hibernateMode: Int)
    /// AC-aware mode could not do what its toggle promises. Informational: this
    /// is a convenience feature, not the data-loss path.
    case acAwareFailed(turningOn: Bool, reason: String)
    /// The primary power-source sensor is unavailable and somnus has fallen back
    /// to coarse polling. The net still works; it just samples less often.
    case monitoringDegraded(reason: String)

    public var title: String {
        switch self {
        case .batteryWarning:      return "Battery low"
        case .safetyNetActed:      return "Stay Awake turned off"
        case .safetyNetRestored:   return "Stay Awake restored"
        case .safetyNetFailed:     return "somnus could not turn Stay Awake off"
        case .safetyNetRestoreFailed: return "somnus could not restore Stay Awake"
        case .sleepRequestFailed:  return "somnus could not sleep the Mac"
        case .preflightRefused:    return "Battery safety net is off"
        case .acAwareFailed:       return "AC-aware mode is not working"
        case .monitoringDegraded:  return "somnus is watching the battery coarsely"
        }
    }

    public var body: String {
        switch self {
        case let .batteryWarning(percent, actThreshold):
            return "Battery \(percent)%: Stay Awake turns off at \(actThreshold)%."
        case let .safetyNetActed(percent, requestedSleep):
            return requestedSleep
                ? "Battery \(percent)%. Stay Awake is off and the Mac is going to sleep now, with everything still open."
                : "Battery \(percent)%. Stay Awake is off: the lid is open, so the Mac will sleep on its normal idle timer. Plug in to keep working."
        case let .safetyNetRestored(percent):
            return "Battery \(percent)%. Stay Awake is back on because somnus previously turned it off to protect the battery."
        case let .safetyNetFailed(percent, reason):
            return "Battery \(percent)% and Stay Awake is still on: \(reason) Turn Stay Awake off manually or plug in now."
        case let .safetyNetRestoreFailed(percent, reason):
            return "Battery \(percent)% has recovered, but somnus could not restore Stay Awake: \(reason) Turn it on manually or check System Integration."
        case let .sleepRequestFailed(percent):
            return "Battery \(percent)% and the Mac did not sleep. Plug in or sleep it manually now."
        case let .preflightRefused(hibernateMode):
            return "hibernatemode is \(hibernateMode); somnus needs 3 or 25 so a full drain during sleep can resume from disk. The safety net will not arm. Nothing was changed."
        case let .acAwareFailed(turningOn, reason):
            return "somnus could not turn Stay Awake \(turningOn ? "on" : "off") when the power source changed: \(reason) Open Settings & Diagnostics from the somnus menu and check System Integration."
        case let .monitoringDegraded(reason):
            return reason
        }
    }

    /// Warnings and convenience-feature failures are informational; the rest are
    /// the data-loss path.
    public var isCritical: Bool {
        switch self {
        case .batteryWarning, .safetyNetRestored, .safetyNetRestoreFailed, .acAwareFailed:
            return false
        default: return true
        }
    }
}

public enum PowerAction: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case safetyNet
        case safetyRestore
        case acAware
    }

    /// Goes to somnusd through `SomnusClient`. Must complete before any later
    /// action in the list runs.
    case setStayAwake(Bool, reason: Reason)
    case notify(PowerNotice)
    /// `pmset sleepnow`, from the unprivileged app. Emitted ONLY when the lid is
    /// known to be closed.
    case requestSleepNow
}

// MARK: - The policy

public struct SafetyNetPolicy: Sendable {

    /// The anti-flap latch. A stage is entered at most once per descent; it is
    /// cleared only by a *recovery* of `rearmMargin` points above the threshold,
    /// so a charge reading oscillating across a boundary (21, 20, 19, 20, 19…)
    /// fires exactly one notification.
    public enum Stage: Int, Sendable, Equatable, Comparable {
        case clear = 0
        case warned = 1
        case acted = 2

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var preferences: PowerPreferences

    /// How far the charge must recover above a threshold before that stage can
    /// fire again. The latch is cleared by charge recovery only: not by
    /// plugging in: so plug/unplug cycling cannot re-trigger it either.
    public let rearmMargin: Int = SafetyNetPolicy.restoreMargin
    /// Points above the off threshold at which an automatic shutoff is restored.
    public static let restoreMargin = 5

    /// After a failed act, how long before somnus tries again. Bounds the retry
    /// so a persistent failure notifies once a minute rather than continuously.
    public let retryInterval: TimeInterval = 60

    public private(set) var stage: Stage = .clear

    /// `false` when the hibernatemode preflight refused.
    public private(set) var isArmed: Bool = true

    /// Provenance, not a mirror of `SleepDisabled`: true only after a confirmed
    /// `.safetyNet` write turned Stay Awake off. This is process-lifetime only;
    /// a relaunch stays conservatively off rather than guessing whether the
    /// user superseded the old restoration intent.
    public private(set) var safetyRestorePending: Bool

    private var preflightNotified = false
    private var lastIsOnAC: Bool?

    /// The previous observation of Stay Awake. `nil` before the first sample -
    /// deliberately NOT treated as "was off": the first sample has no transition
    /// to report, and the latch starts clear, so nothing needs re-arming.
    private var lastStayAwakeOn: Bool?

    /// The act back-off deadline, in MONOTONIC seconds: never an absolute
    /// `Date`. macOS applies NTP corrections after a long sleep, and a wall
    /// clock that steps backwards would hold an absolute deadline in the future
    /// for the length of the step, silencing the net all the way to 0%.
    private var retryNotBeforeElapsed: TimeInterval?
    private var restoreRetryNotBeforeElapsed: TimeInterval?

    /// Monotonic seconds since the first evaluation. See `advanceClock`.
    private var elapsedSeconds: TimeInterval = 0
    private var lastNow: Date?

    public init(preferences: PowerPreferences = .defaults,
                safetyRestorePending: Bool = false) {
        self.preferences = preferences
        self.safetyRestorePending = safetyRestorePending
    }

    /// hibernatemode 3 (safe sleep) or 25 (hibernate) both write a sleep image,
    /// so a full drain while asleep still resumes with RAM intact. With 0 the
    /// guard's entire promise is void, so somnus refuses to arm and says why.
    /// somnus NEVER writes hibernatemode: this is a read-only input.
    public static func preflightPasses(hibernateMode: Int) -> Bool {
        hibernateMode == 3 || hibernateMode == 25
    }

    public mutating func evaluate(_ input: SafetyNetInput, now: Date = Date()) -> [PowerAction] {
        var actions: [PowerAction] = []

        // 0. Monotonic time first: every deadline below is expressed in it, and
        //    it must advance on every sample, including the ones that return
        //    early.
        let elapsed = advanceClock(now)

        // 1. Power-source transition, recorded before anything can return early.
        //    An unreliable read is not a transition and does not replace the
        //    last known source, or one failed read would look like an unplug.
        var acTransition = false
        if input.powerSourceReliable {
            acTransition = (lastIsOnAC != nil && lastIsOnAC != input.isOnAC)
            lastIsOnAC = input.isOnAC
        }

        // 2. Stay Awake being switched back ON is a BRAND NEW hazard and re-arms
        //    the net, whatever the latch says. Without this, a descent that has
        //    already acted is wedged: the latch only demotes at act+margin and
        //    only clears at warn+margin, so if the charge never recovers: the
        //    user re-enables Stay Awake from the Control Center widget, which
        //    talks to somnusd directly and never consults this policy, or
        //    AC-aware mode does it on a plug-in: the net returns nothing at 8%,
        //    5%, 2% and 0%, leaving the Mac awake until the battery is empty.
        //    Re-firing is cheap (`setStayAwake(false)` is idempotent) and being
        //    silent is not, so this deliberately biases towards re-arming.
        let stayAwakeSwitchedOn = (lastStayAwakeOn == false && input.stayAwakeOn)
        lastStayAwakeOn = input.stayAwakeOn
        if stayAwakeSwitchedOn { stage = .clear }

        // 3. Latch maintenance: recovery clears stages.
        updateLatch(for: input)

        // 4. Preflight. Refusal disarms the safety net but not AC-aware mode.
        //    A Mac with no battery cannot drain, so it has nothing to preflight.
        let armed = !input.batteryPresent
            || Self.preflightPasses(hibernateMode: input.hibernateMode)
        isArmed = armed
        if armed {
            preflightNotified = false
        } else if !preflightNotified {
            preflightNotified = true
            actions.append(.notify(.preflightRefused(hibernateMode: input.hibernateMode)))
        }

        // 5. The safety net itself.
        let netActions = armed ? safetyNetActions(for: input, elapsed: elapsed) : []
        actions.append(contentsOf: netActions)

        // 6. Restore only an OFF state that this policy actually caused. The
        //    existing five-point margin prevents 10/11% charge jitter from
        //    flapping the machine between modes. Power source is deliberately
        //    irrelevant: recovery on AC and an unplugged rebound behave alike.
        let restoreActions = armed ? safetyRestoreActions(for: input, elapsed: elapsed) : []
        actions.append(contentsOf: restoreActions)

        // 7. AC-aware mode: acts only on a transition, so a manual toggle made
        //    between transitions stays authoritative until the power source
        //    next changes.
        if acTransition, preferences.acAwareModeEnabled {
            let policyAlreadySetsStayAwake = (netActions + restoreActions).contains {
                if case .setStayAwake = $0 { return true }
                return false
            }
            if !policyAlreadySetsStayAwake, input.isOnAC != input.stayAwakeOn {
                actions.append(.setStayAwake(input.isOnAC, reason: .acAware))
            }
        }

        return actions
    }

    /// Call when a `.setStayAwake(false, reason: .safetyNet)` action failed.
    /// Rolls the latch back so the act stage is retried instead of being
    /// remembered as done, but not before `retryInterval` has passed.
    public mutating func recordActFailure(now: Date) {
        if stage == .acted { stage = .warned }
        retryNotBeforeElapsed = advanceClock(now) + retryInterval
    }

    /// A failed restoration is safe (normal sleep remains enabled), but it must
    /// remain pending and retry without hammering the helper on every battery
    /// notification.
    public mutating func recordRestoreFailure(now: Date) {
        restoreRetryNotBeforeElapsed = advanceClock(now) + retryInterval
    }

    /// An observed user/external ON -> OFF transition supersedes an earlier
    /// automatic-shutoff restoration. Engine-owned writes update the engine's
    /// observed value before their Darwin edge arrives, so only an outside
    /// transition reaches this method.
    public mutating func cancelSafetyRestore() {
        safetyRestorePending = false
        restoreRetryNotBeforeElapsed = nil
    }

    /// Feeds a confirmed engine write back into the sampled-state latch.
    ///
    /// Policy evaluation happens before effects are executed. Without this
    /// feedback, a successful safety-net write to `false` leaves
    /// `lastStayAwakeOn` at its pre-write value (`true`). A direct Control Center
    /// re-enable before another sample would then look like true -> true and
    /// fail to re-arm an `.acted` latch. Turning Stay Awake on always establishes
    /// a fresh hazard, so it clears the latch immediately.
    public mutating func recordStayAwakeWrite(_ on: Bool, reason: PowerAction.Reason) {
        lastStayAwakeOn = on
        switch reason {
        case .safetyNet:
            if !on { safetyRestorePending = true }
        case .safetyRestore:
            if on {
                safetyRestorePending = false
                restoreRetryNotBeforeElapsed = nil
            }
        case .acAware:
            break
        }
        // A user/AC re-enable below the cutoff is a fresh hazard and must clear
        // the act latch. A safety restoration happens only after the recovery
        // margin, where retaining `.warned` avoids a duplicate warning while
        // still allowing another act on a later descent.
        if on, reason != .safetyRestore { stage = .clear }
    }

    // MARK: - Private

    /// Folds the injected wall clock into a counter that cannot run backwards.
    /// The environment injects `now`, which is the seam that keeps the back-off
    /// testable; a `Date`, however, can step BACKWARDS when macOS applies an NTP
    /// correction after a long sleep. Only the non-negative part of each delta
    /// is accumulated, so a backward step costs at most the length of that step
    /// in back-off progress and can never postpone a deadline. A large forward
    /// step only expires a back-off early, which is the safe direction: acting
    /// again costs an idempotent write, not acting can cost every open tab.
    private mutating func advanceClock(_ now: Date) -> TimeInterval {
        defer { lastNow = now }
        guard let lastNow else { return elapsedSeconds }
        elapsedSeconds += max(0, now.timeIntervalSince(lastNow))
        return elapsedSeconds
    }

    private mutating func safetyNetActions(for input: SafetyNetInput, elapsed: TimeInterval) -> [PowerAction] {
        // The net counteracts exactly one hazard: somnus keeping the Mac awake
        // on battery. No battery, on AC, or Stay Awake already off => nothing
        // to do, and the latch is left alone so a later descent still fires.
        guard input.batteryPresent, !input.isOnAC, input.stayAwakeOn else { return [] }

        // The back-off bounds how often a FAILING act is retried, so a
        // persistent failure notifies once a minute rather than continuously.
        // It guards the act stage and nothing else: a warning is free, and
        // suppressing it because the stage below it failed leaves the user with
        // no signal at all.
        let backedOff = retryNotBeforeElapsed.map { elapsed < $0 } ?? false

        if input.batteryPercent <= preferences.actThreshold, stage < .acted, !backedOff {
            retryNotBeforeElapsed = nil
            stage = .acted
            // Lid CLOSED  -> sleep now: nobody is looking, and sleeping beats
            //                draining to a hard power-off.
            // Lid OPEN    -> deliberately do NOT sleep. Yanking the machine out
            //                from under someone mid-work is not acceptable; the
            //                normal idle timer takes it from here.
            // Lid UNKNOWN -> treated as open.
            let sleepNow = (input.lidClosed == true)
            var acted: [PowerAction] = [
                .setStayAwake(false, reason: .safetyNet),
                .notify(.safetyNetActed(percent: input.batteryPercent, requestedSleep: sleepNow))
            ]
            if sleepNow { acted.append(.requestSleepNow) }
            return acted
        }

        if input.batteryPercent <= preferences.warnThreshold, stage < .warned {
            stage = .warned
            return [.notify(.batteryWarning(percent: input.batteryPercent,
                                            actThreshold: preferences.actThreshold))]
        }

        return []
    }

    private mutating func safetyRestoreActions(for input: SafetyNetInput,
                                               elapsed: TimeInterval) -> [PowerAction] {
        guard safetyRestorePending,
              input.batteryPresent,
              input.batteryPercent >= preferences.actThreshold + rearmMargin else {
            return []
        }

        // Another actor may already have turned Stay Awake back on. That still
        // satisfies the recorded intent, so consume ownership without writing.
        if input.stayAwakeOn {
            safetyRestorePending = false
            restoreRetryNotBeforeElapsed = nil
            return []
        }

        if let retry = restoreRetryNotBeforeElapsed, elapsed < retry {
            return []
        }
        restoreRetryNotBeforeElapsed = nil

        return [
            .setStayAwake(true, reason: .safetyRestore),
            .notify(.safetyNetRestored(percent: input.batteryPercent))
        ]
    }

    private mutating func updateLatch(for input: SafetyNetInput) {
        guard input.batteryPresent else {
            stage = .clear
            return
        }
        if input.batteryPercent >= preferences.warnThreshold + rearmMargin {
            stage = .clear
        } else if stage == .acted, input.batteryPercent >= preferences.actThreshold + rearmMargin {
            stage = .warned
        }
    }
}
