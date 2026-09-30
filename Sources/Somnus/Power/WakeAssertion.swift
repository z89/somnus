//  WakeAssertion.swift
//  somnus: the idle assertions that make Stay Awake mean "stay awake".
//
//  `SleepDisabled` (PMSet.writeSleepDisabled) stops the *system* sleeping. It
//  does nothing about the display: `displaysleep` stays at whatever the user's
//  power profile says, and macOS blanks the panel on that timer whether or
//  not sleep is disabled. `SleepDisabled` alone would leave the Mac running
//  with its screen off, on AC and on battery alike, which is not what the
//  toggle promises.
//
//  Two process-owned IOPMAssertions close that gap:
//
//    * PreventUserIdleDisplaySleep: the one that actually matters. This is the
//      assertion `caffeinate -d` takes and the one macOS consults before
//      blanking the display on the idle timer.
//    * PreventUserIdleSystemSleep: belt and braces. `SleepDisabled` already
//      covers idle system sleep, but that is a root write through somnusd that
//      can fail; this one is unprivileged, cannot fail for permission reasons,
//      and costs nothing to hold alongside.
//
//  WHY ASSERTIONS AND NOT `pmset -a displaysleep 0`:
//    * An assertion is owned by this process. If somnus crashes, is force
//      quit, or is killed by the system, the kernel drops it and the Mac
//      returns to the user's own display timer. A written `displaysleep 0`
//      survives the crash and silently keeps the machine misconfigured.
//    * It needs no root, so it does not widen somnusd's API. somnusd remains
//      "read or write SleepDisabled" and nothing else.
//    * It does not overwrite the user's display timer, so there is no original
//      value to remember and restore, and no way to lose it.
//
//  Held for exactly as long as Stay Awake is on. The engine reconciles this to
//  the observed `SleepDisabled` on every evaluation pass and to the confirmed
//  value after every write, so the safety net turning Stay Awake off at 10%
//  releases the display too and the Mac goes back to its normal idle timer.
//
//  The display assertion is the required one. The system assertion is useful
//  redundancy, but failing to acquire it must never discard a valid display
//  assertion and recreate the original "running with a dark screen" bug.

import Foundation
import IOKit.pwr_mgt
import os
import SomnusKit

@MainActor
final class WakeAssertion {

    static let shared = WakeAssertion()

    private static let log = Logger(subsystem: SomnusConstants.appBundleID, category: "power.assertion")

    /// `kIOPMNullAssertionID` is 0, so a zero id means "not held".
    private var displayID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var systemID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    /// Shown in `pmset -g assertions`, so it has to say who and why.
    private static let reason = "Somnus Stay Awake is on" as CFString

    private init() {}

    private(set) var isHeld = false

    /// Idempotent in both directions: the engine calls this on every pass.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        if on {
            acquire()
            return isHeld
        }
        release()
        return true
    }

    private func acquire() {
        guard !isHeld else { return }

        var display = IOPMAssertionID(kIOPMNullAssertionID)
        var system = IOPMAssertionID(kIOPMNullAssertionID)

        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason,
            &display)

        guard displayResult == kIOReturnSuccess else {
            // Loud: the user asked for a screen that stays on and it does not.
            Self.log.fault("Could not take the display assertion (IOReturn \(displayResult, privacy: .public)); the screen will still turn off on the idle timer.")
            return
        }
        displayID = display
        isHeld = true

        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason,
            &system)

        guard systemResult == kIOReturnSuccess else {
            Self.log.error("Could not take the redundant system assertion (IOReturn \(systemResult, privacy: .public)); the required display assertion remains held and SleepDisabled still prevents system sleep.")
            return
        }

        systemID = system
        Self.log.notice("Idle assertions held: the display and the system will not sleep on the idle timer.")
    }

    private func release() {
        guard displayID != kIOPMNullAssertionID || systemID != kIOPMNullAssertionID else { return }

        let displayResult = displayID == kIOPMNullAssertionID
            ? kIOReturnSuccess
            : IOPMAssertionRelease(displayID)
        let systemResult = systemID == kIOPMNullAssertionID
            ? kIOReturnSuccess
            : IOPMAssertionRelease(systemID)

        displayID = IOPMAssertionID(kIOPMNullAssertionID)
        systemID = IOPMAssertionID(kIOPMNullAssertionID)
        isHeld = false

        if displayResult != kIOReturnSuccess || systemResult != kIOReturnSuccess {
            // Recorded, not retried: the ids are already cleared, and a failed
            // release is dropped by the kernel when this process exits anyway.
            Self.log.error("Releasing an idle assertion failed (display \(displayResult, privacy: .public), system \(systemResult, privacy: .public)).")
        } else {
            Self.log.notice("Idle assertions released; the Mac is back on its normal idle timer.")
        }
    }
}
