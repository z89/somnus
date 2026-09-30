//  Battery.swift
//  somnus CLI: unprivileged battery read.
//
//  `somnus status` must report the battery even when somnusd is absent, so this
//  deliberately does NOT go through SomnusClient: it is a plain IOKit power-source
//  read that needs no privileges, no daemon and no entitlement. It is also not a
//  `pmset` invocation: reading IOPS directly avoids parsing human-formatted text.

import Foundation
import IOKit.ps

struct BatteryFacts {

    /// `nil` on a Mac with no internal battery.
    let percent: Int?
    let isOnAC: Bool
    let isCharging: Bool
    /// Minutes, or `nil` when macOS says "still calculating" (it reports -1).
    let minutesToEmpty: Int?
    let minutesToFull: Int?

    static func read() -> BatteryFacts {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            // IOKit refused us entirely. Report the shape honestly rather than
            // inventing a charge level.
            return BatteryFacts(percent: nil, isOnAC: true, isCharging: false,
                                minutesToEmpty: nil, minutesToFull: nil)
        }

        let descriptions = sources.compactMap { source -> [String: Any]? in
            IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        }

        // Prefer the internal battery; a UPS or a Bluetooth mouse also shows up
        // in this list and neither describes the Mac's own charge.
        let internalBattery = descriptions.first {
            $0[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
        }

        guard let battery = internalBattery else {
            // No internal battery: a desktop Mac, permanently on wall power.
            return BatteryFacts(percent: nil, isOnAC: true, isCharging: false,
                                minutesToEmpty: nil, minutesToFull: nil)
        }

        let current = battery[kIOPSCurrentCapacityKey as String] as? Int
        let maximum = battery[kIOPSMaxCapacityKey as String] as? Int
        let percent: Int?
        if let current, let maximum, maximum > 0 {
            let calculated = Int((Double(current) / Double(maximum) * 100).rounded())
            percent = min(max(calculated, 0), 100)
        } else {
            percent = nil
        }

        let state = battery[kIOPSPowerSourceStateKey as String] as? String
        return BatteryFacts(
            percent: percent,
            isOnAC: state == kIOPSACPowerValue,
            isCharging: battery[kIOPSIsChargingKey as String] as? Bool ?? false,
            minutesToEmpty: positive(battery[kIOPSTimeToEmptyKey as String] as? Int),
            minutesToFull: positive(battery[kIOPSTimeToFullChargeKey as String] as? Int))
    }

    /// IOKit uses -1 for "unknown" and 0 for "not applicable in this direction".
    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
