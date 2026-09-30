//  PowerEngineTests.swift
//  somnus: isolated power-engine tests.
//
//  The whole file is behind `SOMNUS_POWER_TESTS`, so it is excluded from the app
//  build and does not require XCTest or a separate test target. Run it with:
//
//    SDK=$(xcrun --show-sdk-path --sdk macosx)
//    SCRATCH=$(mktemp -d)
//    # 1. SomnusKit as a module (SomnusIntents.swift is excluded: it belongs to
//    #    and pulls in AppIntents, which this suite does not need).
//    swiftc -emit-module -emit-library -static -module-name SomnusKit \
//      -target arm64-apple-macos26.0 -sdk "$SDK" -swift-version 5 \
//      -emit-module-path "$SCRATCH/SomnusKit.swiftmodule" -o "$SCRATCH/libSomnusKit.a" \
//      Sources/SomnusKit/PowerTypes.swift Sources/SomnusKit/SomnusClient.swift \
//      Sources/SomnusKit/SomnusConstants.swift Sources/SomnusKit/SomnusError.swift \
//      Sources/SomnusKit/SomnusHelperProtocol.swift Sources/SomnusKit/SomnusCodeRequirement.swift \
//      Sources/SomnusKit/SleepAssertionParser.swift
//    # 2. The engine plus this suite.
//    swiftc -D SOMNUS_POWER_TESTS -target arm64-apple-macos26.0 -sdk "$SDK" \
//      -swift-version 5 -parse-as-library -I "$SCRATCH" -L "$SCRATCH" -lSomnusKit \
//      Sources/Somnus/Power/*.swift Sources/Somnus/Power/Tests/*.swift \
//      -o "$SCRATCH/power-tests" && "$SCRATCH/power-tests"
//
//  Nothing in this suite can sleep the Mac. `pmset sleepnow` is reachable only
//  through `PowerEnvironment.requestSleepNow`, and every environment built here
//  binds that closure to a counter. `PowerEnvironment.live`, the only binding to
//  `SystemSleeper`, is never referenced, and neither is `PowerEngine.shared`.
//  Nor can it post a notification: `notify` is always a recording closure.

#if SOMNUS_POWER_TESTS

import Foundation
import IOKit.ps
import SomnusKit

// MARK: - Entry point

@main
struct PowerTestMain {
    static func main() async {
        let failures = await PowerTestSuite.runAll()
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: - Minimal harness

@MainActor
final class TestReporter {
    private(set) var totalFailures = 0
    private var testFailures = 0
    private var name = "?"
    private var tests = 0

    func begin(_ testName: String) {
        name = testName
        testFailures = 0
        tests += 1
    }

    func end() {
        print(testFailures == 0 ? "PASS  \(name)" : "FAIL  \(name)  (\(testFailures) failed)")
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard !condition else { return }
        testFailures += 1
        totalFailures += 1
        print("        ✗ \(message())")
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        expect(actual == expected, "\(message): got \(actual), expected \(expected)")
    }

    func summary() -> Int {
        print("\n\(tests) tests, \(totalFailures) failures")
        return totalFailures
    }
}

/// A fake machine. Every closure the engine can reach is bound to this object,
/// so nothing in the suite touches IOKit, `pmset`, XPC, UserDefaults or the
/// notification centre.
@MainActor
final class FakeMachine {
    var sample = PowerSourceSample(batteryPercent: 100, batteryPresent: true,
                                   isOnAC: true, isCharging: false)
    var lidClosed: Bool?
    var settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
    var stayAwake = true
    var stayAwakeSetFailure: Error?
    /// Machine-level sleep failure, independent of the `SleepDisabled` coupling
    /// modelled in `requestSleepNow`.
    /// The daemon reports success but `SleepDisabled` does not actually change -
    /// the one way the engine can still be lied to about being safe.
    var stayAwakeSetIsSilentNoOp = false
    var assertions: [SleepAssertion] = []
    var sleepDisabledIsKnown = true
    /// Models an unreadable IORegistry property, which the engine must treat as
    /// UNKNOWN. Otherwise the fast read agrees with `SleepDisabled`, exactly as
    /// it does on a real machine: they are the same value from two sources.
    var fastReadIsUnreadable = false
    var idleAssertionWriteSucceeds = true
    var clock = Date(timeIntervalSince1970: 1_000_000)

    /// Ordered trace of every effect, which is how execution ORDER is asserted:
    /// Stay Awake must be off before the Mac is asked to sleep.
    private(set) var trace: [String] = []
    private(set) var notices: [PowerNotice] = []
    private(set) var sleepRequests = 0
    private(set) var stayAwakeWrites: [Bool] = []
    private(set) var preparedNotificationCount = 0
    private(set) var runLoopSourceRequestCount = 0

    /// Stands in for `WakeAssertion`. Kept OUT of `trace` on purpose: several
    /// tests assert `trace` by exact equality, and the assertion reconciliation
    /// runs on every pass, so tracing it would rewrite all of them.
    private(set) var idleAssertionsHeld = false
    private(set) var idleAssertionWrites: [Bool] = []
    private(set) var controlReloads = 0
    private(set) var stayAwakeObservationStarts = 0
    private(set) var stayAwakeObservationCancels = 0
    private var stayAwakeChangeHandler: (() -> Void)?

    func emitConfirmedStayAwakeChange() {
        stayAwakeChangeHandler?()
    }

    func environment() -> PowerEnvironment {
        PowerEnvironment(
            readPowerSource: { [unowned self] in self.sample },
            readLidClosed: { [unowned self] in self.lidClosed },
            readSleepSettings: { [unowned self] in
                SleepSettings(hibernateMode: self.settings.hibernateMode,
                              sleepDisabled: self.settings.sleepDisabled,
                              sleepDisabledIsKnown: self.sleepDisabledIsKnown)
            },
            readStayAwake: { [unowned self] in self.stayAwake },
            readAssertions: { [unowned self] in self.assertions },
            readSleepDisabledFast: { [unowned self] in
                self.fastReadIsUnreadable ? nil : self.settings.sleepDisabled
            },
            setStayAwake: { [unowned self] on, _ in
                if let failure = self.stayAwakeSetFailure {
                    self.trace.append("set(\(on)) FAILED")
                    throw failure
                }
                self.stayAwakeWrites.append(on)
                if self.stayAwakeSetIsSilentNoOp {
                    self.trace.append("set(\(on)) NO-OP")
                } else {
                    self.stayAwake = on
                    // Stay Awake IS `SleepDisabled`; the two can never disagree
                    // on a real machine, and the sleep path depends on it.
                    self.settings.sleepDisabled = on
                    self.trace.append("set(\(on))")
                }
            },
            requestSleepNow: { [unowned self] in
                self.sleepRequests += 1
                // The real coupling: `pmset sleepnow` returns
                // kIOReturnNotPermitted (0xe00002e2) while `SleepDisabled` is 1.
                // Match pmset behavior. A fake that always succeeds hides
                // every futile sleep request the engine could make.
                guard !self.settings.sleepDisabled else {
                    self.trace.append("sleepnow DENIED (SleepDisabled=1)")
                    return false
                }
                self.trace.append("sleepnow")
                return true
            },
            notify: { [unowned self] notice in
                self.notices.append(notice)
                self.trace.append("notify(\(notice.title))")
            },
            prepareNotifications: { [unowned self] in
                self.preparedNotificationCount += 1
            },
            setIdleAssertions: { [unowned self] on in
                self.idleAssertionWrites.append(on)
                self.idleAssertionsHeld = on && self.idleAssertionWriteSucceeds
                return !on || self.idleAssertionWriteSucceeds
            },
            reloadControlCenter: { [unowned self] in
                self.controlReloads += 1
            },
            observeStayAwakeChanges: { [unowned self] handler in
                self.stayAwakeObservationStarts += 1
                self.stayAwakeChangeHandler = handler
                var cancelled = false
                return { [unowned self] in
                    guard !cancelled else { return }
                    cancelled = true
                    self.stayAwakeChangeHandler = nil
                    self.stayAwakeObservationCancels += 1
                }
            },
            observeManualOffIntents: { _ in { } },
            makeRunLoopSource: { [unowned self] _ in
                self.runLoopSourceRequestCount += 1
                return nil
            },
            loadPreferences: { .defaults },
            savePreferences: { _ in },
            now: { [unowned self] in self.clock })
    }
}

/// A two-pass source for testing the engine evaluation coalescer. Both reads
/// are held behind explicit continuations: no real-time sleeps and no system
/// state are involved.
actor CoalescedRefreshProbe {
    private var reads = 0
    private var firstReadWaiter: CheckedContinuation<Void, Never>?
    private var secondReadWaiter: CheckedContinuation<Void, Never>?
    private var releaseFirst: CheckedContinuation<Void, Never>?
    private var releaseSecond: CheckedContinuation<Void, Never>?

    func readPowerSource() async -> PowerSourceSample {
        reads += 1
        switch reads {
        case 1:
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
                firstReadWaiter?.resume()
                firstReadWaiter = nil
            }
            return PowerSourceSample(batteryPercent: 64, batteryPresent: true,
                                     isOnAC: false, isCharging: false)
        case 2:
            await withCheckedContinuation { continuation in
                releaseSecond = continuation
                secondReadWaiter?.resume()
                secondReadWaiter = nil
            }
            return PowerSourceSample(batteryPercent: 63, batteryPresent: true,
                                     isOnAC: false, isCharging: false)
        default:
            return PowerSourceSample(batteryPercent: 62, batteryPresent: true,
                                     isOnAC: false, isCharging: false)
        }
    }

    func waitForFirstRead() async {
        guard reads == 0 else { return }
        await withCheckedContinuation { firstReadWaiter = $0 }
    }

    func waitForSecondRead() async {
        guard reads < 2 else { return }
        await withCheckedContinuation { secondReadWaiter = $0 }
    }

    func finishFirstRead() {
        releaseFirst?.resume()
        releaseFirst = nil
    }

    func finishSecondRead() {
        releaseSecond?.resume()
        releaseSecond = nil
    }
}

actor CompletionFlag {
    private var value = false

    func markComplete() { value = true }
    func isComplete() -> Bool { value }
}

private func input(percent: Int,
                   present: Bool = true,
                   onAC: Bool = false,
                   charging: Bool = false,
                   stayAwake: Bool = true,
                   lidClosed: Bool? = false,
                   hibernateMode: Int = 3,
                   reliable: Bool = true) -> SafetyNetInput {
    SafetyNetInput(batteryPercent: percent,
                   batteryPresent: present,
                   isOnAC: onAC,
                   isCharging: charging,
                   stayAwakeOn: stayAwake,
                   lidClosed: lidClosed,
                   hibernateMode: hibernateMode,
                   powerSourceReliable: reliable)
}

private func notices(_ actions: [PowerAction]) -> [PowerNotice] {
    actions.compactMap { if case let .notify(notice) = $0 { return notice } else { return nil } }
}

private func requestsSleep(_ actions: [PowerAction]) -> Bool {
    actions.contains(.requestSleepNow)
}

// MARK: - The suite

enum PowerTestSuite {

    @MainActor
    static func runAll() async -> Int {
        let reporter = TestReporter()

        antiFlapWarnFiresOnce(reporter)
        antiFlapOscillationAcrossBoundary(reporter)
        rearmAfterCharging(reporter)
        actFiresOnceThenRearmsAfterRecovery(reporter)
        safetyRestoreRequiresConfirmedPolicyOwnership(reporter)
        safetyRestoreWorksOnBatteryAndAC(reporter)
        failedSafetyRestoreBacksOffAndRetries(reporter)
        lidClosedRequestsSleep(reporter)
        lidOpenDoesNotRequestSleep(reporter)
        lidUnknownDoesNotRequestSleep(reporter)
        preflightRefusesAtHibernateModeZero(reporter)
        preflightArmsAtThreeAndTwentyFive(reporter)
        preflightIsSkippedWithoutABattery(reporter)
        safetyNetIgnoresACAndAbsentBatteryAndStayAwakeOff(reporter)
        acAwareEnablesOnPlugInDisablesOnUnplug(reporter)
        acAwareRespectsManualToggleBetweenTransitions(reporter)
        acAwareDoesNotDuplicateSafetyNetWrite(reporter)
        acAwareIgnoresUnreliablePowerSource(reporter)
        failedActRetriesAfterBackoff(reporter)
        actedThenStayAwakeReenabledBelowMarginActsAgain(reporter)
        warnStillFiresInsideTheActBackOff(reporter)
        backwardClockStepDoesNotSilenceTheNet(reporter)
        assertionParsingRealOutput(reporter)
        assertionParsingNoAssertions(reporter)
        assertionParsingAwkwardNames(reporter)
        pmsetSettingsParsing(reporter)
        powerSourceSamplerIgnoresAccessoryBatteries(reporter)
        powerSourceSamplerRejectsMalformedInternalBattery(reporter)

        await engineActsInOrderWithLidClosed(reporter)
        await engineDoesNotSleepWithLidOpen(reporter)
        await engineNotifiesAndRetriesWhenStayAwakeWriteFails(reporter)
        await engineACAwareTurnsStayAwakeOnAtPlugIn(reporter)
        await engineDoesNotRepeatOnRepeatedEvaluation(reporter)
        await enginePublishesFactsWithUnknownLidAsNotClosed(reporter)
        await enginePublishesTheLatestStayAwakeReading(reporter)
        await engineACAwareReEnableBelowMarginReArmsTheNet(reporter)
        await engineFailedActMakesNoFalseClaimAndNoFutileSleep(reporter)
        await engineReportsASleepDeniedBySleepDisabled(reporter)
        await engineDegradesButKeepsMonitoringWhenNotificationSourceFails(reporter)
        await engineHealthTracksEvaluationTimestamp(reporter)
        await engineWakeTakesAFreshSample(reporter)
        await engineACAwareFailureIsDeduplicatedAndResetsAfterSuccess(reporter)
        await engineReactsToDirectReEnableAfterASuccessfulSafetyWrite(reporter)
        await disablingACAwareClearsFailureAndPermitsANewEpisode(reporter)
        await engineUnknownReadbackAfterAWriteErrorNeverClaimsSafety(reporter)
        await coalescedRefreshWaitsForTheFreshQueuedPass(reporter)
        await engineHoldsIdleAssertionsWhileStayAwakeIsOn(reporter)
        await engineReportsDisplayAssertionFailure(reporter)
        await engineDisarmsOnUnreliablePowerSource(reporter)
        await engineReleasesIdleAssertionsWhenTheSafetyNetActs(reporter)
        await engineTracksIdleAssertionsToStateItDidNotWrite(reporter)
        await engineReloadsControlCenterAfterAnEngineDrivenFlip(reporter)
        await engineLowBatteryShutoffRestoresAfterRecovery(reporter)
        await engineManualOffStaysOffAfterRecovery(reporter)
        await engineOutsideOffCancelsAnEarlierSafetyRestore(reporter)
        await engineRedundantManualOffCancelsAnEarlierSafetyRestore(reporter)
        await engineStopReleasesTheIdleAssertions(reporter)
        await changeEventTakesAssertionsImmediatelyOnAnOutsideEnable(reporter)
        await changeEventEscalatesAnOutsideEnableToAFullEvaluation(reporter)
        await changeEventTreatsAnUnreadableRegistryAsUnknown(reporter)
        await engineOwnsTheChangeObservationForItsMonitoringLifetime(reporter)

        return reporter.summary()
    }

    // MARK: Anti-flap

    @MainActor
    static func antiFlapWarnFiresOnce(_ r: TestReporter) {
        r.begin("warn fires once as the charge falls")
        var policy = SafetyNetPolicy()
        r.expectEqual(notices(policy.evaluate(input(percent: 30))).count, 0, "30% is quiet")
        let first = notices(policy.evaluate(input(percent: 20)))
        r.expectEqual(first.count, 1, "20% warns")
        r.expectEqual(first.first?.body,
                      "Battery 20%: Stay Awake turns off at 10%.",
                      "warning copy")
        for percent in [19, 18, 17, 16, 15, 14, 13, 12, 11] {
            r.expectEqual(policy.evaluate(input(percent: percent)).count, 0,
                          "\(percent)% must not re-warn")
        }
        r.end()
    }

    @MainActor
    static func antiFlapOscillationAcrossBoundary(_ r: TestReporter) {
        r.begin("a charge oscillating across the boundary warns once")
        var policy = SafetyNetPolicy()
        var warnings = 0
        // Real readings jitter: 21, 20, 19, 20, 21, 20, 19 …
        for percent in [21, 20, 19, 20, 21, 20, 19, 20, 21, 20] {
            warnings += notices(policy.evaluate(input(percent: percent))).count
        }
        r.expectEqual(warnings, 1, "exactly one warning across the oscillation")
        r.end()

        r.begin("a charge oscillating across the ACT boundary acts once")
        var actPolicy = SafetyNetPolicy()
        var writes = 0
        var sleeps = 0
        for percent in [11, 10, 9, 10, 11, 10, 9, 8, 9, 10] {
            let actions = actPolicy.evaluate(input(percent: percent, lidClosed: true))
            writes += actions.filter { if case .setStayAwake = $0 { return true } else { return false } }.count
            sleeps += actions.filter { $0 == .requestSleepNow }.count
        }
        r.expectEqual(writes, 1, "exactly one Stay Awake write")
        r.expectEqual(sleeps, 1, "exactly one sleep request")
        r.end()
    }

    @MainActor
    static func rearmAfterCharging(_ r: TestReporter) {
        r.begin("the warn latch clears only after a real recovery")
        var policy = SafetyNetPolicy()
        _ = policy.evaluate(input(percent: 20))
        r.expectEqual(policy.stage, .warned, "latched at warned")
        _ = policy.evaluate(input(percent: 24, onAC: true, charging: true))
        r.expectEqual(policy.stage, .warned, "24% is inside the 5-point rearm margin")
        _ = policy.evaluate(input(percent: 25, onAC: true, charging: true))
        r.expectEqual(policy.stage, .clear, "25% clears the latch")
        r.expectEqual(notices(policy.evaluate(input(percent: 20))).count, 1, "warns again after recovery")
        r.end()
    }

    @MainActor
    static func actFiresOnceThenRearmsAfterRecovery(_ r: TestReporter) {
        r.begin("act fires once, then only after recovering past act+margin")
        var policy = SafetyNetPolicy()
        let acted = policy.evaluate(input(percent: 10, lidClosed: true))
        r.expectEqual(acted.count, 3, "set + notify + sleep")
        r.expectEqual(policy.stage, .acted, "latched at acted")
        r.expectEqual(policy.evaluate(input(percent: 10, lidClosed: true)).count, 0, "no repeat at 10%")
        _ = policy.evaluate(input(percent: 14, onAC: true, charging: true))
        r.expectEqual(policy.stage, .acted, "14% is inside the act rearm margin")
        _ = policy.evaluate(input(percent: 15, onAC: true, charging: true))
        r.expectEqual(policy.stage, .warned, "15% steps the latch back to warned")
        r.expectEqual(notices(policy.evaluate(input(percent: 13))).count, 0, "no fresh warning on the way back down")
        let again = policy.evaluate(input(percent: 10, lidClosed: true))
        r.expectEqual(again.count, 3, "acts again on the second descent")
        r.end()
    }

    @MainActor
    static func safetyRestoreRequiresConfirmedPolicyOwnership(_ r: TestReporter) {
        r.begin("only a confirmed safety-net shutoff creates restoration ownership")
        var policy = SafetyNetPolicy()

        _ = policy.evaluate(input(percent: 10, stayAwake: true))
        r.expect(!policy.safetyRestorePending,
                 "deciding to act is not enough before the write is confirmed")
        policy.recordStayAwakeWrite(false, reason: .safetyNet)
        r.expect(policy.safetyRestorePending,
                 "the confirmed safety write records restoration ownership")

        r.expectEqual(policy.evaluate(input(percent: 14, stayAwake: false)).count, 0,
                      "the five-point recovery margin prevents flapping")
        let restored = policy.evaluate(input(percent: 15, stayAwake: false))
        r.expectEqual(restored.first, .setStayAwake(true, reason: .safetyRestore),
                      "recovery restores the prior ON intent")
        r.expectEqual(notices(restored).first, .safetyNetRestored(percent: 15),
                      "the automatic enable is explained")
        policy.recordStayAwakeWrite(true, reason: .safetyRestore)
        r.expect(!policy.safetyRestorePending, "confirmed restoration consumes ownership")

        var manual = SafetyNetPolicy()
        for source in [
            input(percent: 9, onAC: false, stayAwake: false),
            input(percent: 80, onAC: false, stayAwake: false),
            input(percent: 80, onAC: true, charging: true, stayAwake: false)
        ] {
            r.expectEqual(manual.evaluate(source).count, 0,
                          "a user-originated OFF never becomes an automatic ON")
        }
        r.end()
    }

    @MainActor
    static func safetyRestoreWorksOnBatteryAndAC(_ r: TestReporter) {
        r.begin("safety restoration depends on charge level, not power source")
        for onAC in [false, true] {
            var policy = SafetyNetPolicy(safetyRestorePending: true)
            let actions = policy.evaluate(input(percent: 15,
                                                onAC: onAC,
                                                charging: onAC,
                                                stayAwake: false))
            r.expectEqual(actions.first, .setStayAwake(true, reason: .safetyRestore),
                          onAC ? "restores while charging" : "restores while unplugged")
        }
        r.end()
    }

    @MainActor
    static func failedSafetyRestoreBacksOffAndRetries(_ r: TestReporter) {
        r.begin("a failed safety restoration remains owned and retries after back-off")
        let start = Date(timeIntervalSince1970: 5_000_000)
        var policy = SafetyNetPolicy(safetyRestorePending: true)
        r.expectEqual(policy.evaluate(input(percent: 15, stayAwake: false), now: start).count,
                      2, "restoration is attempted")
        policy.recordRestoreFailure(now: start)
        r.expect(policy.safetyRestorePending, "failure preserves ownership")
        r.expectEqual(policy.evaluate(input(percent: 16, stayAwake: false),
                                     now: start.addingTimeInterval(30)).count,
                      0, "no hammering inside the retry back-off")
        r.expectEqual(policy.evaluate(input(percent: 16, stayAwake: false),
                                     now: start.addingTimeInterval(61)).first,
                      .setStayAwake(true, reason: .safetyRestore),
                      "restoration retries after the back-off")
        r.end()
    }

    // MARK: Lid branch

    @MainActor
    static func lidClosedRequestsSleep(_ r: TestReporter) {
        r.begin("lid CLOSED: Stay Awake off, notify, sleep now")
        var policy = SafetyNetPolicy()
        let actions = policy.evaluate(input(percent: 9, lidClosed: true))
        r.expectEqual(actions.count, 3, "three actions")
        r.expectEqual(actions.first, .setStayAwake(false, reason: .safetyNet), "Stay Awake off first")
        r.expectEqual(actions.last, .requestSleepNow, "sleep last, after the write")
        r.expect(requestsSleep(actions), "sleep is requested")
        r.expectEqual(notices(actions).first,
                      .safetyNetActed(percent: 9, requestedSleep: true),
                      "notice says it is sleeping")
        r.end()
    }

    @MainActor
    static func lidOpenDoesNotRequestSleep(_ r: TestReporter) {
        r.begin("lid OPEN: mode flipped, machine deliberately NOT slept")
        var policy = SafetyNetPolicy()
        let actions = policy.evaluate(input(percent: 9, lidClosed: false))
        r.expectEqual(actions.count, 2, "set + notify only")
        r.expect(!requestsSleep(actions), "NO sleep request with the lid open")
        r.expectEqual(actions.first, .setStayAwake(false, reason: .safetyNet), "Stay Awake still turned off")
        r.expectEqual(notices(actions).first,
                      .safetyNetActed(percent: 9, requestedSleep: false),
                      "notice says the idle timer takes it")
        r.end()
    }

    @MainActor
    static func lidUnknownDoesNotRequestSleep(_ r: TestReporter) {
        r.begin("lid UNKNOWN is treated as open, never as closed")
        var policy = SafetyNetPolicy()
        let actions = policy.evaluate(input(percent: 4, lidClosed: nil))
        r.expect(!requestsSleep(actions), "NO sleep request when the lid state is unknown")
        r.expectEqual(actions.count, 2, "set + notify only")
        r.end()
    }

    // MARK: Preflight

    @MainActor
    static func preflightRefusesAtHibernateModeZero(_ r: TestReporter) {
        r.begin("preflight refuses to arm at hibernatemode 0 and says why")
        var policy = SafetyNetPolicy()
        let actions = policy.evaluate(input(percent: 50, hibernateMode: 0))
        r.expect(!policy.isArmed, "not armed")
        r.expectEqual(notices(actions).count, 1, "one refusal notice")
        r.expectEqual(notices(actions).first, .preflightRefused(hibernateMode: 0), "refusal notice")
        r.expect(notices(actions).first?.body.contains("hibernatemode is 0") == true, "says the mode")
        r.expect(notices(actions).first?.body.contains("3 or 25") == true, "says what is needed")

        // Refusal must not repeat on every notification …
        r.expectEqual(policy.evaluate(input(percent: 49, hibernateMode: 0)).count, 0, "refusal notified once")
        // … and, crucially, a disarmed net takes NO action at all.
        let atFive = policy.evaluate(input(percent: 5, lidClosed: true, hibernateMode: 0))
        r.expectEqual(atFive.count, 0, "disarmed: no writes, no notices, no sleep at 5%")
        r.end()
    }

    @MainActor
    static func preflightArmsAtThreeAndTwentyFive(_ r: TestReporter) {
        r.begin("preflight arms at hibernatemode 3 and 25")
        for mode in [3, 25] {
            var policy = SafetyNetPolicy()
            let actions = policy.evaluate(input(percent: 9, lidClosed: true, hibernateMode: mode))
            r.expect(policy.isArmed, "armed at hibernatemode \(mode)")
            r.expectEqual(actions.count, 3, "acts at hibernatemode \(mode)")
            r.expect(requestsSleep(actions), "sleeps at hibernatemode \(mode)")
        }
        for mode in [0, 1, 7] {
            r.expect(!SafetyNetPolicy.preflightPasses(hibernateMode: mode), "mode \(mode) fails the preflight")
        }
        r.end()
    }

    @MainActor
    static func preflightIsSkippedWithoutABattery(_ r: TestReporter) {
        r.begin("a Mac with no battery arms at any hibernatemode and is not nagged")
        var policy = SafetyNetPolicy()
        let actions = policy.evaluate(input(percent: 100, present: false, onAC: true, hibernateMode: 0))
        r.expect(policy.isArmed, "armed without a battery")
        r.expectEqual(actions.count, 0, "no refusal notice, no writes")
        r.end()
    }

    @MainActor
    static func safetyNetIgnoresACAndAbsentBatteryAndStayAwakeOff(_ r: TestReporter) {
        r.begin("the net only fires on battery, with a battery, with Stay Awake on")
        var onAC = SafetyNetPolicy()
        r.expectEqual(onAC.evaluate(input(percent: 5, onAC: true, charging: true, lidClosed: true)).count, 0,
                      "no action on AC")
        var noBattery = SafetyNetPolicy()
        r.expectEqual(noBattery.evaluate(input(percent: 5, present: false, lidClosed: true)).count, 0,
                      "no action without a battery")
        var stayAwakeOff = SafetyNetPolicy()
        r.expectEqual(stayAwakeOff.evaluate(input(percent: 5, stayAwake: false, lidClosed: true)).count, 0,
                      "no action when Stay Awake is already off")
        // …and the latch is untouched, so turning Stay Awake back on still guards.
        let armed = stayAwakeOff.evaluate(input(percent: 5, stayAwake: true, lidClosed: true))
        r.expectEqual(armed.count, 3, "acts once Stay Awake is switched back on")
        r.end()
    }

    // MARK: AC-aware mode

    @MainActor
    static func acAwareIgnoresUnreliablePowerSource(_ r: TestReporter) {
        r.begin("AC-aware mode never treats an unreliable read as a plug or unplug")
        var policy = SafetyNetPolicy(preferences: PowerPreferences(acAwareModeEnabled: true,
                                                                   warnThreshold: 20,
                                                                   actThreshold: 10))
        _ = policy.evaluate(input(percent: 80, onAC: true, charging: true, stayAwake: true))
        let failedRead = policy.evaluate(input(percent: 0, present: false, onAC: false,
                                               stayAwake: true, reliable: false))
        r.expectEqual(failedRead.count, 0, "a failed read is not an unplug")
        let recovered = policy.evaluate(input(percent: 80, onAC: true, charging: true, stayAwake: true))
        r.expectEqual(recovered.count, 0, "the next good read is not a plug-in")
        r.end()
    }

    @MainActor
    static func acAwareEnablesOnPlugInDisablesOnUnplug(_ r: TestReporter) {
        r.begin("AC-aware mode enables on plug-in and disables on unplug")
        var policy = SafetyNetPolicy(preferences: PowerPreferences(acAwareModeEnabled: true,
                                                                   warnThreshold: 20,
                                                                   actThreshold: 10))
        // First observation establishes a baseline only: no transition yet.
        r.expectEqual(policy.evaluate(input(percent: 80, onAC: false, stayAwake: false)).count, 0,
                      "no action on the first sample")
        let pluggedIn = policy.evaluate(input(percent: 80, onAC: true, charging: true, stayAwake: false))
        r.expectEqual(pluggedIn, [.setStayAwake(true, reason: .acAware)], "plug-in enables Stay Awake")
        let unplugged = policy.evaluate(input(percent: 80, onAC: false, stayAwake: true))
        r.expectEqual(unplugged, [.setStayAwake(false, reason: .acAware)], "unplug disables Stay Awake")

        var off = SafetyNetPolicy()  // acAwareModeEnabled defaults to false
        _ = off.evaluate(input(percent: 80, onAC: false, stayAwake: false))
        r.expectEqual(off.evaluate(input(percent: 80, onAC: true, stayAwake: false)).count, 0,
                      "opt-in: nothing happens when AC-aware mode is off")
        r.end()
    }

    @MainActor
    static func acAwareRespectsManualToggleBetweenTransitions(_ r: TestReporter) {
        r.begin("a manual toggle stays authoritative until the power source changes")
        var policy = SafetyNetPolicy(preferences: PowerPreferences(acAwareModeEnabled: true,
                                                                   warnThreshold: 20,
                                                                   actThreshold: 10))
        _ = policy.evaluate(input(percent: 80, onAC: false, stayAwake: false))
        _ = policy.evaluate(input(percent: 80, onAC: true, charging: true, stayAwake: false))
        // User manually turns Stay Awake off while still on AC. somnus must not
        // put it back: no transition has happened.
        for _ in 0..<5 {
            r.expectEqual(policy.evaluate(input(percent: 80, onAC: true, charging: true, stayAwake: false)).count, 0,
                          "no correction between transitions")
        }
        // The next power-source change takes authority back.
        r.expectEqual(policy.evaluate(input(percent: 80, onAC: false, stayAwake: true)),
                      [.setStayAwake(false, reason: .acAware)],
                      "unplug reasserts AC-aware mode")
        r.end()
    }

    @MainActor
    static func acAwareDoesNotDuplicateSafetyNetWrite(_ r: TestReporter) {
        r.begin("unplugging at 8% writes Stay Awake once, not twice")
        var policy = SafetyNetPolicy(preferences: PowerPreferences(acAwareModeEnabled: true,
                                                                   warnThreshold: 20,
                                                                   actThreshold: 10))
        _ = policy.evaluate(input(percent: 8, onAC: true, charging: true, stayAwake: true, lidClosed: true))
        let unplugged = policy.evaluate(input(percent: 8, onAC: false, stayAwake: true, lidClosed: true))
        let writes = unplugged.filter { if case .setStayAwake = $0 { return true } else { return false } }
        r.expectEqual(writes.count, 1, "one Stay Awake write")
        r.expectEqual(writes.first, .setStayAwake(false, reason: .safetyNet), "the safety net owns it")
        r.expect(requestsSleep(unplugged), "and the lid is closed, so it sleeps")
        r.end()
    }

    // MARK: Failure handling

    @MainActor
    static func failedActRetriesAfterBackoff(_ r: TestReporter) {
        r.begin("a failed act is retried after the back-off, not latched as done")
        var policy = SafetyNetPolicy()
        let start = Date(timeIntervalSince1970: 2_000_000)
        _ = policy.evaluate(input(percent: 9, lidClosed: true), now: start)
        policy.recordActFailure(now: start)
        r.expectEqual(policy.stage, .warned, "latch rolled back off acted")
        r.expectEqual(policy.evaluate(input(percent: 9, lidClosed: true), now: start.addingTimeInterval(30)).count, 0,
                      "no hammering inside the back-off")
        let retried = policy.evaluate(input(percent: 9, lidClosed: true), now: start.addingTimeInterval(61))
        r.expectEqual(retried.count, 3, "retried after the back-off")
        r.end()
    }

    /// Exercises the low-battery sequence. The latch demotes at
    /// act+margin (15%) and clears at warn+margin (25%), so once it has acted
    /// nothing below 15% can re-arm it: and Stay Awake can be switched back on
    /// from the Control Center widget, which talks to somnusd directly and never
    /// consults the engine. Without a re-arm on that transition the net returns
    /// nothing at 8%, 5%, 2% and 0%, and the Mac hard-powers-off.
    @MainActor
    static func actedThenStayAwakeReenabledBelowMarginActsAgain(_ r: TestReporter) {
        r.begin("Stay Awake switched back on below the rearm margin re-arms the net")
        var policy = SafetyNetPolicy()
        _ = policy.evaluate(input(percent: 11, lidClosed: true))
        r.expectEqual(policy.evaluate(input(percent: 10, lidClosed: true)).count, 3, "acts at 10%")
        r.expectEqual(policy.stage, .acted, "latched at acted")

        // somnus's own write took effect, so the next sample reads Stay Awake off.
        r.expectEqual(policy.evaluate(input(percent: 9, stayAwake: false, lidClosed: true)).count, 0,
                      "nothing to do while Stay Awake is off")

        // The user re-enables Stay Awake at 8% while hunting for a charger.
        let again = policy.evaluate(input(percent: 8, stayAwake: true, lidClosed: true))
        r.expectEqual(again.count, 3, "the net acts again at 8%")
        r.expectEqual(again.first, .setStayAwake(false, reason: .safetyNet), "Stay Awake turned off again")
        r.expect(requestsSleep(again), "and the lid is closed, so it sleeps")

        // …at every charge on the way to zero, however often it is switched back on.
        var descent = SafetyNetPolicy()
        _ = descent.evaluate(input(percent: 10, lidClosed: true))
        var writes = 0
        for percent in [8, 5, 2, 0] {
            _ = descent.evaluate(input(percent: percent, stayAwake: false, lidClosed: true))
            writes += descent.evaluate(input(percent: percent, stayAwake: true, lidClosed: true))
                .filter { if case .setStayAwake = $0 { return true } else { return false } }.count
        }
        r.expectEqual(writes, 4, "every re-enable on the way to 0% is answered")

        // The same wedge at the warn stage: a fresh hazard deserves a fresh warning.
        var warnWedge = SafetyNetPolicy()
        _ = warnWedge.evaluate(input(percent: 18))
        _ = warnWedge.evaluate(input(percent: 18, stayAwake: false))
        r.expectEqual(notices(warnWedge.evaluate(input(percent: 18, stayAwake: true))).count, 1,
                      "warns again after Stay Awake is switched back on")
        r.end()
    }

    @MainActor
    static func warnStillFiresInsideTheActBackOff(_ r: TestReporter) {
        r.begin("the act back-off does not suppress the warning stage")
        var policy = SafetyNetPolicy()
        let start = Date(timeIntervalSince1970: 3_000_000)
        _ = policy.evaluate(input(percent: 9, lidClosed: true), now: start)
        policy.recordActFailure(now: start)
        // Charge recovers past warn+margin, so the latch is clear again …
        _ = policy.evaluate(input(percent: 30, onAC: true, charging: true), now: start.addingTimeInterval(5))
        r.expectEqual(policy.stage, .clear, "latch cleared by the recovery")
        // … and the charge falls back to the warn threshold INSIDE the back-off.
        let warned = notices(policy.evaluate(input(percent: 18), now: start.addingTimeInterval(10)))
        r.expectEqual(warned.count, 1, "the warning fires despite the act back-off")
        r.expectEqual(warned.first, .batteryWarning(percent: 18, actThreshold: 10), "the normal warning")
        r.end()
    }

    /// macOS applies NTP corrections after a long sleep, so the wall clock can
    /// step BACKWARDS. An absolute `Date` deadline then blocks the whole net for
    /// the length of the step: an hour of silence all the way to 0%.
    @MainActor
    static func backwardClockStepDoesNotSilenceTheNet(_ r: TestReporter) {
        r.begin("a backward clock step does not silence the net")
        let start = Date(timeIntervalSince1970: 4_000_000)
        let back = start.addingTimeInterval(-3600)

        var policy = SafetyNetPolicy()
        _ = policy.evaluate(input(percent: 9, lidClosed: true), now: start)
        policy.recordActFailure(now: start)
        r.expectEqual(policy.evaluate(input(percent: 9, lidClosed: true), now: back).count, 0,
                      "the back-off has not elapsed yet, so still quiet")
        let retried = policy.evaluate(input(percent: 9, lidClosed: true), now: back.addingTimeInterval(61))
        r.expectEqual(retried.count, 3, "61 seconds of real time later the act is retried")

        var warnPolicy = SafetyNetPolicy()
        _ = warnPolicy.evaluate(input(percent: 9, lidClosed: true), now: start)
        warnPolicy.recordActFailure(now: start)
        _ = warnPolicy.evaluate(input(percent: 30, onAC: true, charging: true), now: back)
        let warned = notices(warnPolicy.evaluate(input(percent: 19), now: back.addingTimeInterval(5)))
        r.expectEqual(warned.count, 1, "the warning still fires after the clock steps back")
        r.end()
    }

    // MARK: `pmset -g assertions`

    /// Representative `/usr/bin/pmset -g assertions` output.
    static let realAssertionsOutput = """
    2026-01-01 12:00:00 +0000
    Assertion status system-wide:
       BackgroundTask                 0
       ApplePushServiceTask           0
       UserIsActive                   1
       PreventUserIdleDisplaySleep    0
       SoftwareUpdateTask             0
       PreventSystemSleep             0
       ExternalMedia                  0
       InternalPreventDisplaySleep    1
       PreventUserIdleSystemSleep     1
       NetworkClientActive            0
    Listed by owning process:
       pid 353(powerd): [0x0000c3050001987c] 01:01:43 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
       pid 353(powerd): [0x0000ce9f001082bf] 00:00:00 InternalPreventDisplaySleep named: "com.apple.powermanagement.delayDisplayOff"
    \tTimeout will fire in 300 secs Action=TimeoutActionTurnOff
       pid 743(caffeinate): [0x0000d12400019abb] 00:01:28 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
    \tDetails: caffeinate asserting for 300 secs
    \tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
    \tTimeout will fire in 212 secs Action=TimeoutActionRelease
       pid 744(caffeinate): [0x0000d11100019ab2] 00:01:47 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
    \tDetails: caffeinate asserting for 300 secs
    \tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
    \tTimeout will fire in 193 secs Action=TimeoutActionRelease
       pid 404(bluetoothd): [0x0000d17800019aca] 00:00:03 PreventUserIdleSystemSleep named: "com.apple.BTStack"
       pid 3131(Electron): [0x0000d20000019b01] 00:12:00 NoIdleSleepAssertion named: "Electron"
       pid 412(WindowServer): [0x0000c3050009987b] 00:00:00 UserIsActive named: "com.apple.iohideventsystem.queue.tickle serviceID:100000ff1 service:AppleMultitouchDevice product:Apple Internal Keyboard / Trackpad eventType:11"
    \tTimeout will fire in 600 secs Action=TimeoutActionRelease
    Kernel Assertions: 0x4=USB
       id=684  level=255 0x4=USB creat= description=com.apple.usb.externaldevice.01200000 owner=iPhone
    """

    /// What the same command prints when nothing is holding the Mac awake:
    /// every counter zero and an empty process section.
    static let noAssertionsOutput = """
    2026-01-01 12:00:00 +0000
    Assertion status system-wide:
       BackgroundTask                 0
       ApplePushServiceTask           0
       UserIsActive                   0
       PreventUserIdleDisplaySleep    0
       SoftwareUpdateTask             0
       PreventSystemSleep             0
       ExternalMedia                  0
       InternalPreventDisplaySleep    0
       PreventUserIdleSystemSleep     0
       NetworkClientActive            0
    Listed by owning process:
    Kernel Assertions: None
    """

    @MainActor
    static func assertionParsingRealOutput(_ r: TestReporter) {
        r.begin("pmset -g assertions parses real captured output")
        let parsed = SleepAssertionParser.parse(realAssertionsOutput)
        r.expectEqual(parsed.count, 7, "seven process-owned assertions")

        r.expectEqual(parsed.first?.pid, 353, "first pid")
        r.expectEqual(parsed.first?.processName, "powerd", "first process")
        r.expectEqual(parsed.first?.type, "PreventUserIdleSystemSleep", "first type")
        r.expectEqual(parsed.first?.id, "0x0000c3050001987c", "assertion id")
        r.expectEqual(parsed.first?.detail, "Powerd - Prevent sleep while display is on", "named text")

        let caffeinates = parsed.filter { $0.processName == "caffeinate" }
        r.expectEqual(caffeinates.count, 2, "both stray caffeinate processes")
        r.expectEqual(caffeinates.first?.pid, 743, "caffeinate pid")
        r.expect(caffeinates.first?.detail?.contains("asserting for 300 secs") == true,
                 "the Details: continuation line is folded into detail")

        let electron = parsed.first { $0.type == "NoIdleSleepAssertion" }
        r.expect(electron != nil, "the Electron NoIdleSleepAssertion is found")
        r.expectEqual(electron?.pid, 3131, "Electron pid")

        r.expect(!parsed.contains { $0.processName.contains("iPhone") },
                 "kernel assertions are not misparsed as process assertions")
        r.expectEqual(Set(parsed.map(\.id)).count, parsed.count, "ids are unique (Identifiable)")

        let windowServer = parsed.first { $0.processName == "WindowServer" }
        r.expect(windowServer?.detail?.contains("AppleMultitouchDevice") == true,
                 "a named string containing colons survives")
        r.end()
    }

    @MainActor
    static func assertionParsingNoAssertions(_ r: TestReporter) {
        r.begin("pmset -g assertions with nothing holding the Mac awake")
        r.expectEqual(SleepAssertionParser.parse(noAssertionsOutput).count, 0, "empty list, no crash")
        r.expectEqual(SleepAssertionParser.parse("").count, 0, "empty input")
        r.expectEqual(SleepAssertionParser.parse("garbage\nnot pmset output").count, 0, "junk input")
        r.end()
    }

    @MainActor
    static func assertionParsingAwkwardNames(_ r: TestReporter) {
        r.begin("process names containing parentheses parse correctly")
        let text = """
        Listed by owning process:
           pid 900(Google Chrome Helper (Renderer)): [0x0000abcd00001111] 00:00:05 PreventUserIdleSystemSleep named: "video playback"
           pid 901(mediaremoted): [0x0000abcd00002222] 00:00:06 PreventUserIdleSystemSleep
        """
        let parsed = SleepAssertionParser.parse(text)
        r.expectEqual(parsed.count, 2, "both lines parsed")
        r.expectEqual(parsed.first?.processName, "Google Chrome Helper (Renderer)", "nested parentheses")
        r.expectEqual(parsed.last?.detail, nil, "a line with no named: has no detail")
        r.end()
    }

    @MainActor
    static func pmsetSettingsParsing(_ r: TestReporter) {
        r.begin("pmset -g parses hibernatemode and SleepDisabled")
        let text = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         hibernatefile        /var/vm/sleepimage
         sleep                1 (sleep prevented by powerd, caffeinate)
         hibernatemode        3
         displaysleep         10
        """
        let settings = PMSet.parseSleepSettings(text)
        r.expectEqual(settings.hibernateMode, 3, "hibernatemode")
        r.expectEqual(settings.sleepDisabled, true, "SleepDisabled 1")

        let off = PMSet.parseSleepSettings("System-wide power settings:\n SleepDisabled\t\t0\n hibernatemode        25\n")
        r.expectEqual(off.sleepDisabled, false, "SleepDisabled 0")
        r.expectEqual(off.hibernateMode, 25, "hibernatemode 25")

        let absent = PMSet.parseSleepSettings("Currently in use:\n standby              1\n hibernatemode        3\n")
        r.expect(absent.sleepDisabledIsKnown, "a missing key in valid output is known")
        r.expectEqual(absent.sleepDisabled, false, "a missing key is the default, off")

        let invalid = PMSet.parseSleepSettings("System-wide power settings:\n SleepDisabled\t\tmaybe\n hibernatemode        3\n")
        r.expect(!invalid.sleepDisabledIsKnown, "an unreadable value leaves SleepDisabled unknown")
        r.expectEqual(invalid.hibernateMode, 3, "an unreadable SleepDisabled keeps the other settings")

        let empty = PMSet.parseSleepSettings("")
        r.expect(!empty.sleepDisabledIsKnown, "unreadable output leaves SleepDisabled unknown")
        r.expectEqual(empty.hibernateMode, 0, "unreadable output fails the preflight rather than passing it")
        r.end()
    }

    @MainActor
    static func powerSourceSamplerIgnoresAccessoryBatteries(_ r: TestReporter) {
        r.begin("power source sampler selects the internal battery")
        let accessory: [String: Any] = [
            kIOPSTypeKey as String: "UPS",
            kIOPSCurrentCapacityKey as String: 5,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSIsChargingKey as String: false,
        ]
        let internalBattery: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey as String: 48,
            kIOPSMaxCapacityKey as String: 80,
            kIOPSIsChargingKey as String: true,
        ]

        let sample = PowerSourceSampler.sample(
            from: [accessory, internalBattery], isOnAC: true)
        r.expectEqual(sample.batteryPercent, 60, "internal battery percentage")
        r.expect(sample.batteryPresent, "internal battery is present")
        r.expect(sample.isCharging, "internal battery charging state")
        r.end()
    }

    @MainActor
    static func powerSourceSamplerRejectsMalformedInternalBattery(_ r: TestReporter) {
        r.begin("power source sampler distinguishes a failed battery read")
        let malformed: [String: Any] = [
            kIOPSTypeKey as String: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey as String: 48,
        ]
        let sample = PowerSourceSampler.sample(from: [malformed], isOnAC: false)
        r.expect(!sample.isReliable, "missing capacity is unknown, not a desktop")
        r.expect(!sample.batteryPresent, "unknown data is never fed to battery policy")
        r.end()
    }

    // MARK: Engine-level (the executor and its seams)

    // MARK: Idle assertions
    //
    // `SleepDisabled` stops the system sleeping and nothing else: the display
    // still blanks on the `displaysleep` timer. These prove the assertions that
    // close that gap are held for exactly as long as Stay Awake is on, and in
    // particular that the safety net releases them so the Mac can idle down at
    // the act threshold.

    @MainActor
    static func engineHoldsIdleAssertionsWhileStayAwakeIsOn(_ r: TestReporter) async {
        r.begin("engine: Stay Awake on -> idle assertions held, on battery too")
        let machine = FakeMachine()
        machine.stayAwake = true
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
        // On battery and well above the warn threshold: the power source must
        // make no difference at all to whether the display is held awake.
        machine.sample = PowerSourceSample(batteryPercent: 67, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expect(machine.idleAssertionsHeld, "the display and system assertions are held on battery")
        r.expectEqual(machine.notices.count, 0, "67% is quiet")
        r.end()
    }

    @MainActor
    static func engineReportsDisplayAssertionFailure(_ r: TestReporter) async {
        r.begin("engine: display assertion failure is visible in health")
        let machine = FakeMachine()
        machine.idleAssertionWriteSucceeds = false
        let engine = PowerEngine(environment: machine.environment())

        await engine.evaluate(includeAssertions: false)

        r.expect(!engine.health.idleAssertionsHealthy, "health records the failed assertion")
        r.expect(!engine.health.isHealthy, "overall health is degraded")
        r.end()
    }

    @MainActor
    static func engineDisarmsOnUnreliablePowerSource(_ r: TestReporter) async {
        r.begin("engine: an unreliable battery read disarms the safety net")
        let machine = FakeMachine()
        machine.sample = .unknown()
        let engine = PowerEngine(environment: machine.environment())

        await engine.evaluate(includeAssertions: false)
        r.expect(!engine.health.safetyNetArmed, "unknown battery state is not called protected")
        r.expect(engine.health.monitoringDegradedReason != nil, "degradation is visible")
        r.expectEqual(machine.stayAwakeWrites, [], "unknown battery data never drives a write")

        machine.sample = PowerSourceSample(batteryPercent: 80, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        await engine.evaluate(includeAssertions: false)
        r.expect(engine.health.safetyNetArmed, "a trustworthy sample re-arms protection")
        r.end()
    }

    @MainActor
    static func engineReleasesIdleAssertionsWhenTheSafetyNetActs(_ r: TestReporter) async {
        r.begin("engine: safety net acts -> idle assertions released")
        let machine = FakeMachine()
        machine.stayAwake = true
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
        machine.sample = PowerSourceSample(batteryPercent: 9, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = false
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.stayAwake, false, "Stay Awake turned off at 9%")
        r.expect(!machine.idleAssertionsHeld,
                 "the assertions are released, so the Mac falls back to its normal idle timer")
        // Held first (reconciled to the observed state), then dropped with the
        // write: never dropped and re-taken.
        r.expectEqual(machine.idleAssertionWrites, [true, false], "held, then released once")
        r.end()
    }

    @MainActor
    static func engineTracksIdleAssertionsToStateItDidNotWrite(_ r: TestReporter) async {
        r.begin("engine: Stay Awake turned on elsewhere -> assertions still taken")
        let machine = FakeMachine()
        // The widget and the CLI talk to somnusd directly; the engine only ever
        // learns about those flips by observing them on a pass.
        machine.stayAwake = false
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: false)
        machine.sample = PowerSourceSample(batteryPercent: 80, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)
        r.expect(!machine.idleAssertionsHeld, "nothing held while Stay Awake is off")

        machine.stayAwake = true
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
        await engine.evaluate(includeAssertions: false)
        r.expect(machine.idleAssertionsHeld, "the next pass notices and takes them")
        r.expectEqual(machine.stayAwakeWrites.count, 0, "the engine wrote nothing itself")
        r.end()
    }

    @MainActor
    static func engineReloadsControlCenterAfterAnEngineDrivenFlip(_ r: TestReporter) async {
        r.begin("engine: an engine-driven flip refreshes the Control Center toggle")
        let machine = FakeMachine()
        machine.stayAwake = true
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
        machine.sample = PowerSourceSample(batteryPercent: 9, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = false
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.stayAwakeWrites, [false], "the safety net wrote once")
        r.expectEqual(engine.facts?.sleepDisabled, false,
                      "the published snapshot follows the confirmed write")
        r.expectEqual(machine.controlReloads, 1,
                      "the widget is told to re-read, so it cannot keep showing Stay Awake")
        r.end()
    }

    @MainActor
    static func engineLowBatteryShutoffRestoresAfterRecovery(_ r: TestReporter) async {
        r.begin("engine: low-battery shutoff restores after recovery")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 10, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())

        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false], "10% turns Stay Awake off")
        r.expectEqual(engine.facts?.sleepDisabled, false, "the engine publishes the off state")
        r.expect(!machine.idleAssertionsHeld, "the idle assertions are released")
        r.expectEqual(machine.controlReloads, 1, "the shutoff requests a control refresh")
        r.expect(engine.safetyRestorePending,
                 "the confirmed safety write records restoration ownership")

        machine.sample = PowerSourceSample(batteryPercent: 14, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false], "14% remains inside the margin")

        machine.sample = PowerSourceSample(batteryPercent: 15, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.stayAwakeWrites, [false, true],
                      "15% restores even while unplugged")
        r.expectEqual(engine.facts?.sleepDisabled, true, "the restored state is published")
        r.expect(machine.idleAssertionsHeld, "restoration takes the idle assertions again")
        r.expect(!engine.safetyRestorePending, "confirmed restoration consumes ownership")
        r.end()
    }

    @MainActor
    static func engineManualOffStaysOffAfterRecovery(_ r: TestReporter) async {
        r.begin("engine: a user-originated off remains off after recovery")
        let machine = FakeMachine()
        machine.stayAwake = false
        machine.settings.sleepDisabled = false
        machine.sample = PowerSourceSample(batteryPercent: 9, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())

        await engine.evaluate(includeAssertions: false)
        machine.sample = PowerSourceSample(batteryPercent: 80, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.stayAwakeWrites, [], "Somnus never claims a manual off")
        r.expect(!engine.safetyRestorePending, "no restoration marker was invented")
        r.expectEqual(engine.facts?.sleepDisabled, false, "normal sleep remains enabled")
        r.end()
    }

    @MainActor
    static func engineOutsideOffCancelsAnEarlierSafetyRestore(_ r: TestReporter) async {
        r.begin("engine: an outside off transition cancels earlier restoration ownership")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 10, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        machine.sample = PowerSourceSample(batteryPercent: 12, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        machine.stayAwake = true
        machine.settings.sleepDisabled = true
        await engine.handleStayAwakeChange()

        // Models Control Center/CLI/user code, not an action from `perform`.
        machine.stayAwake = false
        machine.settings.sleepDisabled = false
        await engine.handleStayAwakeChange()

        r.expect(!engine.safetyRestorePending, "the user's newer OFF intent wins")
        machine.sample.batteryPercent = 80
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false], "recovery does not undo that OFF")
        r.end()
    }

    @MainActor
    static func engineRedundantManualOffCancelsAnEarlierSafetyRestore(_ r: TestReporter) async {
        r.begin("engine: a redundant explicit off cancels automatic restoration")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 10, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)
        r.expect(engine.safetyRestorePending, "safety action owns restoration")

        engine.handleManualOffIntent()
        machine.sample.batteryPercent = 80
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.stayAwakeWrites, [false], "redundant OFF prevents later ON")
        r.expect(!engine.safetyRestorePending, "explicit intent clears ownership")
        r.end()
    }

    @MainActor
    static func engineStopReleasesTheIdleAssertions(_ r: TestReporter) async {
        r.begin("engine: stop() releases the idle assertions")
        let machine = FakeMachine()
        machine.stayAwake = true
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
        machine.sample = PowerSourceSample(batteryPercent: 90, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)
        r.expect(machine.idleAssertionsHeld, "held while running")

        engine.stop()
        r.expect(!machine.idleAssertionsHeld, "an engine that has stopped holds nothing awake")
        r.end()
    }

    @MainActor
    static func changeEventTakesAssertionsImmediatelyOnAnOutsideEnable(_ r: TestReporter) async {
        r.begin("change event: an outside enable takes assertions and reloads the control")
        let machine = FakeMachine()
        machine.stayAwake = false
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: false)
        machine.sample = PowerSourceSample(batteryPercent: 80, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)
        r.expect(!machine.idleAssertionsHeld, "nothing held to begin with")

        // The Control Center widget and the CLI both write through somnusd,
        // which emits this event only after the new value is confirmed.
        machine.stayAwake = true
        machine.settings.sleepDisabled = true
        await engine.handleStayAwakeChange()

        r.expect(machine.idleAssertionsHeld, "the event takes them immediately")
        r.expectEqual(machine.controlReloads, 1, "the event reloads Control Center")
        r.end()
    }

    @MainActor
    static func changeEventEscalatesAnOutsideEnableToAFullEvaluation(_ r: TestReporter) async {
        r.begin("change event: an outside enable at 8% re-arms the safety net at once")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 8, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = false
        let engine = PowerEngine(environment: machine.environment())

        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false], "the net acts on the first descent")
        r.expectEqual(engine.safetyNetStage, .acted, "and latches")

        // Re-enabled from Control Center, below the rearm margin. Before the
        // event existed this was invisible until the 5-minute backstop.
        machine.stayAwake = true
        machine.settings.sleepDisabled = true
        await engine.handleStayAwakeChange()

        r.expectEqual(machine.stayAwakeWrites, [false, false],
                      "the event escalated to a pass and the net acted again")
        r.expect(!machine.idleAssertionsHeld,
                 "and the assertions ended released, with Stay Awake back off")
        r.expectEqual(machine.controlReloads, 3,
                      "event, safety write and confirmed follow-up all refresh the control")
        r.end()
    }

    @MainActor
    static func changeEventTreatsAnUnreadableRegistryAsUnknown(_ r: TestReporter) async {
        r.begin("change event: an unreadable fast value never drops a held assertion")
        let machine = FakeMachine()
        machine.stayAwake = true
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
        machine.sample = PowerSourceSample(batteryPercent: 70, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)
        r.expect(machine.idleAssertionsHeld, "held while Stay Awake is on")

        machine.fastReadIsUnreadable = true
        let writesBefore = machine.idleAssertionWrites.count
        await engine.handleStayAwakeChange()

        r.expect(machine.idleAssertionsHeld, "unknown is not false: still held")
        r.expectEqual(machine.idleAssertionWrites.count, writesBefore + 1,
                      "the authoritative full read safely reasserts the true value")
        r.expectEqual(machine.controlReloads, 1,
                      "the control refresh does not depend on the fast read")
        r.end()
    }

    @MainActor
    static func engineOwnsTheChangeObservationForItsMonitoringLifetime(_ r: TestReporter) async {
        r.begin("change event: observer follows the engine monitoring lifetime")
        let machine = FakeMachine()
        machine.stayAwake = false
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: false)
        let engine = PowerEngine(environment: machine.environment())

        engine.start()
        for _ in 0..<3 { await Task.yield() }
        r.expectEqual(machine.stayAwakeObservationStarts, 1,
                      "start registers exactly one observer")

        machine.stayAwake = true
        machine.settings.sleepDisabled = true
        machine.emitConfirmedStayAwakeChange()
        for _ in 0..<5 { await Task.yield() }

        r.expectEqual(engine.facts?.sleepDisabled, true,
                      "the registered event path publishes the new state")
        r.expect(machine.idleAssertionsHeld,
                 "the registered event path takes idle assertions")
        r.expectEqual(machine.controlReloads, 1,
                      "the registered event path reloads Control Center")

        engine.stop()
        r.expectEqual(machine.stayAwakeObservationCancels, 1,
                      "stop cancels exactly one observer")
        machine.settings.sleepDisabled = false
        machine.emitConfirmedStayAwakeChange()
        for _ in 0..<3 { await Task.yield() }
        r.expectEqual(machine.controlReloads, 1,
                      "a stopped engine receives no more events")
        r.end()
    }

    @MainActor
    static func engineActsInOrderWithLidClosed(_ r: TestReporter) async {
        r.begin("engine: lid closed -> off, notify, sleep, in that order")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 9, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.trace, ["set(false)", "notify(Stay Awake turned off)", "sleepnow"],
                      "effects in order")
        r.expectEqual(machine.sleepRequests, 1, "exactly one sleep request")
        r.expectEqual(machine.stayAwake, false, "Stay Awake really went off")
        r.expectEqual(engine.safetyNetStage, .acted, "latched")
        r.end()
    }

    @MainActor
    static func engineDoesNotSleepWithLidOpen(_ r: TestReporter) async {
        r.begin("engine: lid open -> mode flipped, machine NOT slept")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 9, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = false
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.sleepRequests, 0, "NO sleep request")
        r.expectEqual(machine.trace, ["set(false)", "notify(Stay Awake turned off)"], "no sleepnow in the trace")
        r.expectEqual(machine.stayAwake, false, "Stay Awake still turned off")
        r.end()
    }

    @MainActor
    static func engineNotifiesAndRetriesWhenStayAwakeWriteFails(_ r: TestReporter) async {
        r.begin("engine: a failed Stay Awake write notifies loudly and retries")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 8, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        machine.stayAwakeSetFailure = SomnusError.helperNotInstalled
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expect(machine.notices.contains { if case .safetyNetFailed = $0 { return true } else { return false } },
                 "the user is told the safety net could not act")
        // Best effort still beats draining to 0%: but a sleep request cannot
        // work here: `SleepDisabled` is still 1, so `pmset sleepnow` returns
        // kIOReturnNotPermitted. Asking anyway only produces a second, confusing
        // notification.
        r.expectEqual(machine.sleepRequests, 0, "no futile sleep request while SleepDisabled is 1")
        r.expectEqual(engine.safetyNetStage, .warned, "the failure is not latched as success")

        // Inside the back-off: quiet. After it: retried.
        machine.clock = machine.clock.addingTimeInterval(10)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites.count, 0, "no hammering inside the back-off")

        machine.stayAwakeSetFailure = nil
        machine.clock = machine.clock.addingTimeInterval(120)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwake, false, "the retry succeeded")
        r.expectEqual(machine.sleepRequests, 1, "and it slept on the retry, once Stay Awake was really off")
        r.end()
    }

    @MainActor
    static func engineACAwareTurnsStayAwakeOnAtPlugIn(_ r: TestReporter) async {
        r.begin("engine: AC-aware mode follows the cable")
        let machine = FakeMachine()
        machine.stayAwake = false
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        engine.acAwareModeEnabled = true
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites.count, 0, "baseline sample writes nothing")

        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [true], "plug-in enabled Stay Awake")

        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [true, false], "unplug disabled Stay Awake")
        r.expectEqual(machine.sleepRequests, 0, "AC-aware mode never sleeps the Mac")
        r.end()
    }

    @MainActor
    static func engineDoesNotRepeatOnRepeatedEvaluation(_ r: TestReporter) async {
        r.begin("engine: repeated notifications do not repeat the action")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 10, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        let engine = PowerEngine(environment: machine.environment())
        for _ in 0..<10 {
            await engine.evaluate(includeAssertions: false)
        }
        r.expectEqual(machine.sleepRequests, 1, "one sleep request across ten notifications")
        r.expectEqual(machine.stayAwakeWrites, [false], "one Stay Awake write")
        r.expectEqual(machine.notices.count, 1, "one notification")
        r.end()
    }

    @MainActor
    static func enginePublishesFactsWithUnknownLidAsNotClosed(_ r: TestReporter) async {
        r.begin("engine: publishes PowerFacts, unknown lid reported as not closed")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 43, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = nil
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: true)
        machine.assertions = [SleepAssertion(id: "0x1", pid: 1, processName: "caffeinate",
                                             type: "PreventUserIdleSystemSleep", detail: nil)]
        let engine = PowerEngine(environment: machine.environment())
        await engine.refresh()

        r.expectEqual(engine.facts?.batteryPercent, 43, "battery percent")
        r.expectEqual(engine.facts?.isOnAC, false, "on battery")
        r.expectEqual(engine.facts?.lidClosed, false, "unknown lid is published as not closed")
        r.expectEqual(engine.facts?.hibernateMode, 3, "hibernatemode")
        r.expectEqual(engine.facts?.sleepDisabled, true, "SleepDisabled")
        r.expectEqual(engine.assertions.count, 1, "assertions published by refresh()")
        r.expect(engine.safetyNetArmed, "armed at hibernatemode 3")
        r.expectEqual(machine.sleepRequests, 0, "43% does nothing")
        r.end()
    }

    @MainActor
    static func enginePublishesTheLatestStayAwakeReading(_ r: TestReporter) async {
        r.begin("engine: publishes the latest Stay Awake reading")
        let machine = FakeMachine()
        machine.settings = SleepSettings(hibernateMode: 3, sleepDisabled: false)
        machine.stayAwake = true
        let engine = PowerEngine(environment: machine.environment())

        await engine.refresh()

        r.expectEqual(engine.facts?.sleepDisabled, true,
                      "facts use the later helper reading")
        r.end()
    }

    /// The same wedge as `actedThenStayAwakeReenabledBelowMarginActsAgain`, but
    /// reached through AC-aware mode rather than a human: plugging in at 9%
    /// turns Stay Awake back ON with the latch still at `.acted`, and the charge
    /// never recovers far enough to clear it.
    @MainActor
    static func engineACAwareReEnableBelowMarginReArmsTheNet(_ r: TestReporter) async {
        r.begin("engine: AC-aware re-enabling Stay Awake below the margin re-arms the net")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 10, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        let engine = PowerEngine(environment: machine.environment())
        engine.acAwareModeEnabled = true
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false], "acted at 10%")
        r.expectEqual(engine.safetyNetStage, .acted, "latched at acted")

        // Plugged in at 9%: AC-aware mode turns Stay Awake back on.
        machine.sample = PowerSourceSample(batteryPercent: 9, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false, true], "AC-aware re-enabled Stay Awake")

        // The charger is knocked out at 8%. The battery never got near 15%.
        machine.sample = PowerSourceSample(batteryPercent: 8, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false, true, false], "the net turns Stay Awake off again")
        r.expectEqual(machine.sleepRequests, 2, "and sleeps again: the lid is still closed")
        r.expectEqual(machine.notices.filter { if case .safetyNetActed = $0 { return true } else { return false } }.count,
                      2, "the user is told both times")
        r.end()
    }

    @MainActor
    static func engineFailedActMakesNoFalseClaimAndNoFutileSleep(_ r: TestReporter) async {
        r.begin("engine: a failed act never claims success and never asks for an impossible sleep")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 8, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        machine.stayAwakeSetFailure = SomnusError.helperNotInstalled
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expect(machine.settings.sleepDisabled, "SleepDisabled really is still 1")
        r.expect(!machine.notices.contains { if case .safetyNetActed = $0 { return true } else { return false } },
                 "NO notice saying Stay Awake is off and the Mac is going to sleep")
        r.expect(machine.notices.contains { if case .safetyNetFailed = $0 { return true } else { return false } },
                 "the honest notice is posted instead")
        r.expectEqual(machine.sleepRequests, 0,
                      "no sleep request: pmset sleepnow cannot succeed while SleepDisabled is 1")
        r.expect(!machine.notices.contains { if case .sleepRequestFailed = $0 { return true } else { return false } },
                 "and so no second notice about a sleep that could never have worked")
        r.expectEqual(machine.trace, ["set(false) FAILED", "notify(somnus could not turn Stay Awake off)"],
                      "exactly two effects: the attempt and the honest report")
        r.expectEqual(engine.safetyNetStage, .warned, "the failure is not latched as success")
        r.end()
    }

    /// Models a helper that reports success while the setting does not change.
    /// Independent readback must reject the no-op before any success claim or
    /// impossible sleep request is made.
    @MainActor
    static func engineReportsASleepDeniedBySleepDisabled(_ r: TestReporter) async {
        r.begin("engine: a silent no-op is rejected before sleep")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 7, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        machine.stayAwakeSetIsSilentNoOp = true
        let engine = PowerEngine(environment: machine.environment())
        await engine.evaluate(includeAssertions: false)

        r.expect(machine.settings.sleepDisabled, "the write was a silent no-op")
        r.expectEqual(machine.sleepRequests, 0, "no impossible sleep request is made")
        r.expect(!machine.trace.contains("sleepnow DENIED (SleepDisabled=1)"), "the kernel is not asked")
        r.expect(machine.notices.contains { if case .safetyNetFailed = $0 { return true } else { return false } },
                 "the user gets the honest safety failure")
        r.expect(!machine.notices.contains { if case .sleepRequestFailed = $0 { return true } else { return false } },
                 "there is no contradictory sleep failure")
        r.expectEqual(engine.safetyNetStage, .warned, "the action is rolled back for retry")
        r.end()
    }

    @MainActor
    static func engineDegradesButKeepsMonitoringWhenNotificationSourceFails(_ r: TestReporter) async {
        r.begin("engine: a missing IOKit source degrades monitoring without stopping it")
        let machine = FakeMachine()
        let engine = PowerEngine(environment: machine.environment())

        r.expect(!engine.isMonitoring, "a new engine is not monitoring")
        r.expectEqual(engine.health.lastEvaluation, nil, "no sample before start")

        engine.start()
        r.expect(engine.isMonitoring, "the periodic backstop keeps monitoring alive")
        r.expect(engine.monitoringDegradedReason?.contains("every minute") == true,
                 "the degraded reason explains the backstop")
        r.expectEqual(machine.preparedNotificationCount, 1, "notifications prepared once")
        r.expectEqual(machine.runLoopSourceRequestCount, 1, "IOKit source attempted once")
        r.expect(!engine.health.isHealthy, "a degraded monitor is not healthy")

        // Let the retained initial refresh finish before checking idempotence.
        // stop() also cancels it when it is still pending.
        for _ in 0..<3 { await Task.yield() }

        // start() is idempotent: it must not create a second timer, observer or
        // retained callback context while the first monitoring session lives.
        engine.start()
        r.expectEqual(machine.preparedNotificationCount, 1, "second start is a no-op")
        r.expectEqual(machine.runLoopSourceRequestCount, 1, "second start does not retry immediately")

        engine.stop()
        r.expect(!engine.isMonitoring, "stop ends monitoring")
        r.expectEqual(engine.monitoringDegradedReason, nil, "stop clears the stale degraded status")
        r.expect(!engine.health.isHealthy, "a stopped engine is not healthy")
        r.end()
    }

    @MainActor
    static func engineHealthTracksEvaluationTimestamp(_ r: TestReporter) async {
        r.begin("engine: health records the timestamp of each completed sample")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 64, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.clock = Date(timeIntervalSince1970: 5_000_000)
        let engine = PowerEngine(environment: machine.environment())

        r.expectEqual(engine.lastEvaluation, nil, "timestamp begins empty")
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(engine.lastEvaluation, machine.clock, "timestamp is the evaluation clock")
        r.expectEqual(engine.health.lastEvaluation, machine.clock, "health exposes the same timestamp")
        r.expect(engine.health.safetyNetArmed, "valid hibernatemode leaves the net armed")
        r.expect(!engine.health.isHealthy, "sampling alone is not monitoring")

        machine.clock = machine.clock.addingTimeInterval(42)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(engine.lastEvaluation, machine.clock, "a later sample replaces the timestamp")
        r.end()
    }

    @MainActor
    static func engineWakeTakesAFreshSample(_ r: TestReporter) async {
        r.begin("engine: wake schedules a fresh safety-net evaluation")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 80, batteryPresent: true,
                                           isOnAC: true, isCharging: false)
        machine.clock = Date(timeIntervalSince1970: 5_000_000)
        let engine = PowerEngine(environment: machine.environment())
        engine.start()
        for _ in 0..<3 { await Task.yield() }

        machine.sample = PowerSourceSample(batteryPercent: 43, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.clock = Date(timeIntervalSince1970: 6_000_000)
        engine.systemDidWake()
        // systemDidWake intentionally uses a task so the notification callback
        // never blocks the workspace notification centre. Yielding is enough to
        // let that main-actor task run; no wall-clock wait is involved.
        for _ in 0..<3 { await Task.yield() }

        r.expectEqual(engine.facts?.batteryPercent, 43, "wake reads the current battery sample")
        r.expectEqual(engine.lastEvaluation, machine.clock, "wake updates the health timestamp")
        r.expectEqual(machine.controlReloads, 1, "wake retries the Control Center refresh")
        r.expectEqual(machine.sleepRequests, 0, "the harmless wake sample cannot sleep the Mac")
        engine.stop()
        r.end()
    }

    @MainActor
    static func engineACAwareFailureIsDeduplicatedAndResetsAfterSuccess(_ r: TestReporter) async {
        r.begin("engine: AC-aware failures report once, clear on success, then report a new episode")
        let machine = FakeMachine()
        machine.stayAwake = false
        machine.settings.sleepDisabled = false
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        engine.acAwareModeEnabled = true
        await engine.evaluate(includeAssertions: false) // establish the AC baseline

        machine.stayAwakeSetFailure = SomnusError.helperNotInstalled
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(engine.acAwareLastFailureReason, SomnusError.helperNotInstalled.localizedDescription,
                      "the failed write is visible in engine health")
        r.expect(!engine.health.isHealthy, "an AC-aware failure makes health unhealthy")
        r.expectEqual(machine.notices.filter { if case .acAwareFailed = $0 { return true } else { return false } }.count,
                      1, "the first failure is reported")

        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.notices.filter { if case .acAwareFailed = $0 { return true } else { return false } }.count,
                      1, "plug/unplug does not repeat a standing failure")

        machine.stayAwakeSetFailure = nil
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(engine.acAwareLastFailureReason, nil, "a successful write clears the failure")

        machine.stayAwakeSetFailure = SomnusError.helperNotInstalled
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.notices.filter { if case .acAwareFailed = $0 { return true } else { return false } }.count,
                      2, "a new failure episode reports again after recovery")
        r.end()
    }

    /// The Control Center extension writes through the helper, not through the
    /// engine. Its direct re-enable must therefore re-arm a just-acted policy
    /// even when the engine never observed an intervening Stay Awake-off sample.
    @MainActor
    static func engineReactsToDirectReEnableAfterASuccessfulSafetyWrite(_ r: TestReporter) async {
        r.begin("engine: a direct re-enable after a successful safety write acts again")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 8, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        let engine = PowerEngine(environment: machine.environment())

        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.stayAwakeWrites, [false], "first descent turns Stay Awake off")
        r.expectEqual(engine.safetyNetStage, .acted, "first descent is latched")

        // Model a Control Center write between power samples.
        machine.stayAwake = true
        machine.settings.sleepDisabled = true
        await engine.evaluate(includeAssertions: false)

        r.expectEqual(machine.stayAwakeWrites, [false, false],
                      "the direct re-enable gets a second safety write")
        r.expectEqual(machine.sleepRequests, 2, "the closed-lid safety action sleeps again")
        r.expectEqual(engine.safetyNetStage, .acted, "the second descent is also latched")
        r.end()
    }

    @MainActor
    static func disablingACAwareClearsFailureAndPermitsANewEpisode(_ r: TestReporter) async {
        r.begin("engine: disabling AC-aware clears a failure and re-enabling starts a new episode")
        let machine = FakeMachine()
        machine.stayAwake = false
        machine.settings.sleepDisabled = false
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        let engine = PowerEngine(environment: machine.environment())
        engine.acAwareModeEnabled = true
        await engine.evaluate(includeAssertions: false)

        machine.stayAwakeSetFailure = SomnusError.helperNotInstalled
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: true, isCharging: true)
        await engine.evaluate(includeAssertions: false)
        r.expect(engine.acAwareLastFailureReason != nil, "the initial failure is recorded")
        r.expectEqual(machine.notices.filter { if case .acAwareFailed = $0 { return true } else { return false } }.count,
                      1, "the initial failure is reported")

        engine.acAwareModeEnabled = false
        r.expectEqual(engine.acAwareLastFailureReason, nil, "turning the feature off clears stale failure state")

        engine.acAwareModeEnabled = true
        // The failed plug-in never changed the real setting. Model a user
        // turning it on before the next cable transition, so unplugging has a
        // fresh AC-aware write to attempt.
        machine.stayAwake = true
        machine.settings.sleepDisabled = true
        machine.sample = PowerSourceSample(batteryPercent: 60, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        await engine.evaluate(includeAssertions: false)
        r.expectEqual(machine.notices.filter { if case .acAwareFailed = $0 { return true } else { return false } }.count,
                      2, "the re-enabled feature reports its own new failure")
        r.end()
    }

    @MainActor
    static func engineUnknownReadbackAfterAWriteErrorNeverClaimsSafety(_ r: TestReporter) async {
        r.begin("engine: an unknown local readback after a write error never claims safety")
        let machine = FakeMachine()
        machine.sample = PowerSourceSample(batteryPercent: 8, batteryPresent: true,
                                           isOnAC: false, isCharging: false)
        machine.lidClosed = true
        machine.stayAwakeSetFailure = SomnusError.helperNotInstalled
        // Match the old `.unknown` representation: false was a placeholder, not
        // evidence that Stay Awake was actually off.
        machine.settings.sleepDisabled = false
        machine.sleepDisabledIsKnown = false
        let engine = PowerEngine(environment: machine.environment())

        await engine.evaluate(includeAssertions: false)

        r.expect(!machine.notices.contains { if case .safetyNetActed = $0 { return true } else { return false } },
                 "unknown is not treated as confirmation that Stay Awake is off")
        r.expect(machine.notices.contains { if case .safetyNetFailed = $0 { return true } else { return false } },
                 "the unconfirmed failure is reported honestly")
        r.expectEqual(machine.sleepRequests, 0, "no sleep is requested without confirmed disarm")
        r.expectEqual(engine.safetyNetStage, .warned, "the net rolls back for retry")
        r.end()
    }

    @MainActor
    static func coalescedRefreshWaitsForTheFreshQueuedPass(_ r: TestReporter) async {
        r.begin("engine: a coalesced refresh waits for the queued fresh pass")
        let probe = CoalescedRefreshProbe()
        let environment = PowerEnvironment(
            readPowerSource: { await probe.readPowerSource() },
            readLidClosed: { false },
            readSleepSettings: { SleepSettings(hibernateMode: 3, sleepDisabled: false) },
            readStayAwake: { false },
            readAssertions: { [] },
            readSleepDisabledFast: { false },
            setStayAwake: { _, _ in },
            requestSleepNow: { false },
            notify: { _ in },
            prepareNotifications: { },
            setIdleAssertions: { _ in true },
            reloadControlCenter: { },
            observeStayAwakeChanges: { _ in { } },
            observeManualOffIntents: { _ in { } },
            makeRunLoopSource: { _ in nil },
            loadPreferences: { .defaults },
            savePreferences: { _ in },
            now: { Date(timeIntervalSince1970: 7_000_000) })
        let engine = PowerEngine(environment: environment)
        let secondRefreshReturned = CompletionFlag()

        let first = Task { @MainActor in await engine.refresh() }
        await probe.waitForFirstRead()
        let second = Task { @MainActor in
            await engine.refresh()
            await secondRefreshReturned.markComplete()
        }
        for _ in 0..<3 { await Task.yield() }
        let returnedBeforeFreshPass = await secondRefreshReturned.isComplete()
        r.expect(!returnedBeforeFreshPass,
                 "the coalesced caller does not return before its fresh pass")

        await probe.finishFirstRead()
        await probe.waitForSecondRead()
        let returnedWhileFreshPassSamples = await secondRefreshReturned.isComplete()
        r.expect(!returnedWhileFreshPassSamples,
                 "the coalesced caller remains pending while its pass samples")
        await probe.finishSecondRead()
        await first.value
        await second.value

        r.expectEqual(engine.facts?.batteryPercent, 63,
                      "the coalesced caller returns only after fresh facts arrive")
        r.end()
    }
}

#endif
