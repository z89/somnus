#if SOMNUS_CONTROL_TESTS

import Foundation

@main
struct StayAwakeControlTests {
    static func main() {
        var failures = 0
        func expect(_ actual: StayAwakeValue.DisplayState,
                    _ expected: StayAwakeValue.DisplayState,
                    _ name: String) {
            if actual != expected {
                failures += 1
                print("FAIL  \(name): \(actual) != \(expected)")
            }
        }
        func value(on: Bool = false,
                   helper: Bool = true,
                   app: Bool = true,
                   armed: Bool = true,
                   degraded: Bool = false,
                   ac: Bool = false) -> StayAwakeValue {
            StayAwakeValue(isOn: on,
                           helperReachable: helper,
                           appRunning: app,
                           safetyNetArmed: armed,
                           monitoringDegraded: degraded,
                           acAwareModeEnabled: ac)
        }

        expect(value(helper: false, app: true, armed: true, ac: true).displayState,
               .unavailable, "helper failure wins")
        expect(value(app: false).displayState, .appNotRunning, "stopped while off")
        expect(value(on: true, app: false).displayState, .unprotected, "stopped while on")
        expect(value(armed: false).displayState, .safetyNetOff, "disarmed")
        expect(value(degraded: true).displayState, .monitoringDegraded, "degraded")
        expect(value(ac: true).displayState, .normalSleep(acAware: true), "AC auto off")
        expect(value(on: true, ac: true).displayState, .stayAwake(acAware: true), "AC auto on")
        expect(value().displayState, .normalSleep(acAware: false), "normal")
        expect(value(on: true).displayState, .stayAwake(acAware: false), "awake")

        print(failures == 0 ? "control display tests passed, 0 failures" : "control failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

#endif
