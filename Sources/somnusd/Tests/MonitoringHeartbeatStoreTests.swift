#if SOMNUS_HEARTBEAT_TESTS

import Foundation

@main
struct MonitoringHeartbeatStoreTests {
    static func main() {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures += 1
                print("FAIL  \(message)")
            }
        }

        let store = MonitoringHeartbeatStore(timeout: 90, startedAt: 100)
        expect(store.snapshot(at: 100) == MonitoringHeartbeatSnapshot(
            appRunning: false,
            safetyNetArmed: false,
            monitoringDegraded: false,
            acAwareModeEnabled: false), "initial state is offline")

        store.report(running: true,
                     safetyNetArmed: true,
                     monitoringDegraded: false,
                     acAwareModeEnabled: true,
                     at: 100)
        expect(store.snapshot(at: 190).appRunning, "heartbeat is valid at the boundary")
        expect(store.snapshot(at: 190).acAwareModeEnabled, "AC-aware state is retained")

        let expired = store.snapshot(at: 190.001)
        expect(!expired.appRunning, "heartbeat expires after the boundary")
        expect(!expired.safetyNetArmed, "expired heartbeat cannot claim protection")

        store.report(running: true,
                     safetyNetArmed: true,
                     monitoringDegraded: true,
                     acAwareModeEnabled: false,
                     at: 200)
        expect(store.snapshot(at: 201).monitoringDegraded,
               "degraded monitoring is reported while alive")

        store.report(running: false,
                     safetyNetArmed: true,
                     monitoringDegraded: false,
                     acAwareModeEnabled: true,
                     at: 202)
        let stopped = store.snapshot(at: 202)
        expect(!stopped.appRunning, "explicit stop is immediate")
        expect(!stopped.safetyNetArmed, "explicit stop clears protection")
        expect(store.shouldRunWatchdog(at: 202), "explicit stop arms the watchdog immediately")
        store.markWatchdogHandled()
        expect(!store.shouldRunWatchdog(at: 203), "one lapse triggers one completed watchdog action")

        store.report(running: true,
                     safetyNetArmed: true,
                     monitoringDegraded: false,
                     acAwareModeEnabled: false,
                     at: 210)
        expect(!store.shouldRunWatchdog(at: 300), "fresh armed heartbeat suppresses watchdog")
        expect(store.shouldRunWatchdog(at: 300.001), "expired protection re-arms watchdog")

        // Regression: a protected report between two unprotected ones starts
        // a new lapse even if no watchdog pass ran while it was fresh.
        let quickLapse = MonitoringHeartbeatStore(timeout: 90, startedAt: 0)
        quickLapse.report(running: false, safetyNetArmed: false,
                          monitoringDegraded: false, acAwareModeEnabled: false, at: 10)
        expect(quickLapse.shouldRunWatchdog(at: 10), "first lapse runs the watchdog")
        quickLapse.markWatchdogHandled()
        quickLapse.report(running: true, safetyNetArmed: true,
                          monitoringDegraded: false, acAwareModeEnabled: false, at: 20)
        quickLapse.report(running: true, safetyNetArmed: false,
                          monitoringDegraded: false, acAwareModeEnabled: false, at: 21)
        expect(quickLapse.shouldRunWatchdog(at: 21), "a second lapse runs the watchdog again")

        // A protected report that lands while the watchdog is acting must not
        // mark the next lapse as handled.
        let racing = MonitoringHeartbeatStore(timeout: 90, startedAt: 0)
        racing.report(running: false, safetyNetArmed: false,
                      monitoringDegraded: false, acAwareModeEnabled: false, at: 10)
        expect(racing.shouldRunWatchdog(at: 10), "lapse before the race runs the watchdog")
        racing.report(running: true, safetyNetArmed: true,
                      monitoringDegraded: false, acAwareModeEnabled: false, at: 11)
        racing.markWatchdogHandled()
        racing.report(running: false, safetyNetArmed: false,
                      monitoringDegraded: false, acAwareModeEnabled: false, at: 12)
        expect(racing.shouldRunWatchdog(at: 12), "a lapse after the race still runs the watchdog")

        let neverReported = MonitoringHeartbeatStore(timeout: 90, startedAt: 100)
        expect(!neverReported.shouldRunWatchdog(at: 190), "new daemon gets startup grace")
        expect(neverReported.shouldRunWatchdog(at: 190.001), "missing startup heartbeat expires")

        expect(PMSet.parseSleepDisabled("""
            System-wide power settings:
             SleepDisabled        1
            """) == true, "parses enabled SleepDisabled")
        expect(PMSet.parseSleepDisabled("""
            System-wide power settings:
             SleepDisabled        0
            """) == false, "parses disabled SleepDisabled")
        expect(PMSet.parseSleepDisabled("""
            System-wide power settings:
             Currently in use:
              hibernatemode        3
            """) == false, "accepts an absent SleepDisabled default")
        expect(PMSet.parseSleepDisabled("""
            Currently in use:
             hibernatemode        3
             sleep                1
            """) == false, "accepts output without a system-wide section")
        expect(PMSet.parseSleepDisabled("unexpected output") == nil,
               "rejects malformed pmset output")
        expect(PMSet.parseSleepDisabled("""
            System-wide power settings:
             SleepDisabled        maybe
            """) == nil, "rejects an invalid SleepDisabled value")

        print(failures == 0 ? "helper tests passed, 0 failures" : "helper failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

#endif
