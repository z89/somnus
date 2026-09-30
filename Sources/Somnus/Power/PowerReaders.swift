//  PowerReaders.swift
//  somnus: power readers.
//
//  Every read of real machine state lives here, and nothing here decides
//  anything. All of it is unprivileged and read-only, except `SystemSleeper`,
//  which is the single place `pmset sleepnow` can be issued from.

import Foundation
import IOKit
import IOKit.ps
import os
import SomnusKit

// MARK: - Samples

/// One reading of the power source. `batteryPresent` is false on a Mac with no
/// battery, where the safety net must never fire.
public struct PowerSourceSample: Equatable, Sendable {
    public var batteryPercent: Int
    public var batteryPresent: Bool
    public var isOnAC: Bool
    public var isCharging: Bool
    public var isReliable: Bool

    public init(batteryPercent: Int,
                batteryPresent: Bool,
                isOnAC: Bool,
                isCharging: Bool,
                isReliable: Bool = true) {
        self.batteryPercent = batteryPercent
        self.batteryPresent = batteryPresent
        self.isOnAC = isOnAC
        self.isCharging = isCharging
        self.isReliable = isReliable
    }

    /// What a machine with no readable battery looks like: on AC, nothing to guard.
    public static let noBattery = PowerSourceSample(batteryPercent: 100,
                                                    batteryPresent: false,
                                                    isOnAC: true,
                                                    isCharging: false)

    public static func unknown(isOnAC: Bool = false) -> PowerSourceSample {
        PowerSourceSample(batteryPercent: 0,
                          batteryPresent: false,
                          isOnAC: isOnAC,
                          isCharging: false,
                          isReliable: false)
    }
}

/// The two `pmset -g` values the engine needs. `hibernateMode` is READ ONLY -
/// somnus never writes it.
public struct SleepSettings: Equatable, Sendable {
    public var hibernateMode: Int
    public var sleepDisabled: Bool
    /// `false` when `pmset -g` failed or did not contain a valid
    /// `SleepDisabled` value. A write confirmation must never treat the
    /// fallback `false` as proof that Stay Awake is off.
    public var sleepDisabledIsKnown: Bool

    public init(hibernateMode: Int, sleepDisabled: Bool, sleepDisabledIsKnown: Bool = true) {
        self.hibernateMode = hibernateMode
        self.sleepDisabled = sleepDisabled
        self.sleepDisabledIsKnown = sleepDisabledIsKnown
    }

    /// Used when `pmset -g` cannot be read at all. hibernatemode 0 fails the
    /// preflight, so an unreadable machine disarms the net loudly instead of
    /// pretending it is protected.
    public static let unknown = SleepSettings(hibernateMode: 0, sleepDisabled: false,
                                               sleepDisabledIsKnown: false)
}

// MARK: - IOKit power source

public enum PowerSourceSampler {

    private static let log = Logger(subsystem: SomnusConstants.appBundleID, category: "power.source")

    /// Synchronous IOKit read. Cheap, but called from a detached task anyway so
    /// the main actor never waits on IOKit.
    public static func sample() -> PowerSourceSample {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            log.error("IOPSCopyPowerSourcesInfo returned nothing.")
            return .unknown()
        }

        // `Get`, not `Copy`: takeUnretainedValue.
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        guard let providing else {
            log.error("IOPSGetProvidingPowerSourceType returned nothing.")
            return .unknown()
        }
        let isOnAC = (providing == kIOPSACPowerValue)

        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else {
            log.error("IOPSCopyPowerSourcesList returned nothing.")
            return .unknown(isOnAC: isOnAC)
        }

        var missingDescription = false
        let descriptions = (list as NSArray).compactMap { element -> [String: Any]? in
            guard let value = IOPSGetPowerSourceDescription(blob, element as AnyObject)?
                .takeUnretainedValue()
            else {
                missingDescription = true
                return nil
            }
            return value as NSDictionary as? [String: Any]
        }
        if missingDescription {
            log.error("A power-source description could not be read.")
            return .unknown(isOnAC: isOnAC)
        }
        return sample(from: descriptions, isOnAC: isOnAC)
    }

    /// Builds a sample from IOKit descriptions. Accessories and UPS devices can
    /// appear before the internal battery, so they must not drive battery policy.
    static func sample(from descriptions: [[String: Any]], isOnAC: Bool) -> PowerSourceSample {
        guard let battery = descriptions.first(where: {
            $0[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
        }) else {
            return PowerSourceSample(batteryPercent: 100,
                                     batteryPresent: false,
                                     isOnAC: isOnAC,
                                     isCharging: false)
        }
        guard let current = battery[kIOPSCurrentCapacityKey as String] as? Int,
        let maximum = battery[kIOPSMaxCapacityKey as String] as? Int,
        maximum > 0 else {
            return .unknown(isOnAC: isOnAC)
        }

        let percent = Int((Double(current) / Double(maximum) * 100).rounded())
        return PowerSourceSample(
            batteryPercent: min(max(percent, 0), 100),
            batteryPresent: true,
            isOnAC: isOnAC,
            isCharging: battery[kIOPSIsChargingKey as String] as? Bool ?? false)
    }

    /// Installs the IOKit power-source notification. Returned source is caller-owned.
    public static func makeRunLoopSource(callback: @escaping IOPowerSourceCallbackType,
                                         context: UnsafeMutableRawPointer?) -> CFRunLoopSource? {
        IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue()
    }
}

// MARK: - Lid

public enum LidSensor {

    /// `AppleClamshellState` from `IOPMrootDomain`. Unprivileged and sandbox-safe
    ///
    ///
    /// Returns `nil` when the property is absent: a Mac with no lid, or an
    /// external-display-only setup. **`nil` means unknown and must never be
    /// treated as "closed"**: the closed branch sleeps the machine.
    ///
    /// This is a snapshot. Read it at the moment of the decision, never cached
    /// from an earlier notification.
    public static func lidClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root,
                                                    "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault,
                                                    0)?.takeRetainedValue()
        return value as? Bool
    }
}

// MARK: - SleepDisabled, cheaply

/// The same value `pmset -g` prints as `SleepDisabled`, read straight out of
/// the IORegistry instead of out of a subprocess.
///
/// `PMSet.readSleepSettings()` spawns `/usr/bin/pmset` and parses it, which is
/// fine on the engine's five-minute fallback pass and unnecessary on the hot
/// path. This is ~10µs, so the engine can reconcile idle assertions immediately
/// when somnusd emits its confirmed-change event.
public enum SleepDisabledSensor {

    /// Returns `nil` when the property is absent or unreadable. `nil` means
    /// UNKNOWN and the caller must leave the assertions exactly as they are
    /// until the full helper/`pmset -g` read completes. A momentary unreadable
    /// registry must never be allowed to drop a held assertion.
    public static func read() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault,
                                               IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root,
                                                    "SleepDisabled" as CFString,
                                                    kCFAllocatorDefault,
                                                    0)?.takeRetainedValue()
        // The property is a CFBoolean here, but it is bridged as NSNumber on
        // some paths; go through NSNumber so both read correctly.
        return (value as? NSNumber)?.boolValue
    }
}

// MARK: - pmset

public enum PMSet {

    public static let executable = "/usr/bin/pmset"
    static let timeout: TimeInterval = 10
    static let killGrace: TimeInterval = 2
    static let drainGrace: TimeInterval = 1

    private static let log = Logger(subsystem: SomnusConstants.appBundleID, category: "power.pmset")

    /// Runs `/usr/bin/pmset` with a FIXED argument array: never a shell string,
    /// never interpolation of anything a caller supplied.
    /// Returns `nil` if the tool cannot be run, fails, or exceeds its deadline.
    static func run(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        let outputRead = DispatchSemaphore(value: 0)
        let data = LockedData()
        let terminate = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
        }
        let forceTerminate = DispatchWorkItem {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        process.terminationHandler = { _ in
            terminate.cancel()
            forceTerminate.cancel()
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            log.error("Could not run pmset \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        DispatchQueue.global(qos: .utility).async {
            data.set(output.fileHandleForReading.readDataToEndOfFile())
            outputRead.signal()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: terminate)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + killGrace,
                                                       execute: forceTerminate)

        guard exited.wait(timeout: .now() + timeout + killGrace + drainGrace) == .success else {
            terminate.cancel()
            forceTerminate.cancel()
            log.error("pmset \(arguments.joined(separator: " "), privacy: .public) did not exit before its deadline.")
            return nil
        }
        _ = outputRead.wait(timeout: .now() + drainGrace)
        guard process.terminationStatus == 0 else {
            log.error("pmset \(arguments.joined(separator: " "), privacy: .public) exited \(process.terminationStatus, privacy: .public).")
            return nil
        }
        return String(decoding: data.snapshot(), as: UTF8.self)
    }

    /// `pmset -g`: a read. Requires no privileges.
    public static func readSleepSettings() -> SleepSettings {
        guard let text = run(["-g"]) else { return .unknown }
        return parseSleepSettings(text)
    }

    /// `pmset -g assertions`: a read. Requires no privileges.
    public static func readAssertions() -> [SleepAssertion] {
        guard let text = run(["-g", "assertions"]) else { return [] }
        return SleepAssertionParser.parse(text)
    }

    /// Parses the `SleepDisabled` and `hibernatemode` lines out of `pmset -g`.
    /// Tolerates the tab-separated system-wide block and the space-padded
    /// "Currently in use" block, and ignores everything else.
    public static func parseSleepSettings(_ text: String) -> SleepSettings {
        var hibernateMode = 0
        var sleepDisabled = false
        var sleepDisabledIsKnown = false
        var sleepDisabledIsInvalid = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = fields.first else { continue }
            let value = fields.count >= 2 ? fields[1].lowercased() : ""
            switch key {
            case "hibernatemode":
                hibernateMode = Int(value) ?? hibernateMode
            case "SleepDisabled":
                switch value {
                case "1", "true", "yes":
                    sleepDisabled = true
                    sleepDisabledIsKnown = true
                case "0", "false", "no":
                    sleepDisabled = false
                    sleepDisabledIsKnown = true
                default:
                    sleepDisabledIsInvalid = true
                }
            default:
                continue
            }
        }
        // Same rules as somnusd's `PMSet.parseSleepDisabled`: macOS omits the
        // key until it has been set, so its absence from otherwise valid
        // output is the default, off. A key with a value that cannot be read
        // is unknown, never off.
        if sleepDisabledIsInvalid {
            sleepDisabled = false
            sleepDisabledIsKnown = false
        } else if !sleepDisabledIsKnown,
                  text.contains("System-wide power settings:") || text.contains("Currently in use:") {
            sleepDisabledIsKnown = true
        }
        return SleepSettings(hibernateMode: hibernateMode,
                             sleepDisabled: sleepDisabled,
                             sleepDisabledIsKnown: sleepDisabledIsKnown)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let value = data
        lock.unlock()
        return value
    }
}

// MARK: - The sleep path

/// The ONLY place in somnus that asks the Mac to sleep.
///
/// ⚠️ `pmset sleepnow` is deliberately kept in the UNPRIVILEGED app, not in the
/// root daemon: `IOPMLib.h` says the caller "must be root or the console
/// user", and keeping it out of somnusd shrinks the privileged surface.
///
/// This path still requires hardware-level verification on supported Macs.
/// Nothing in the test suite reaches this type: the engine only ever sleeps
/// through `PowerEnvironment.requestSleepNow`, and every test injects a stub
/// closure that records the request instead. `PowerEnvironment.live` is the one
/// and only binding of that closure to this code.
public enum SystemSleeper {

    private static let log = Logger(subsystem: SomnusConstants.appBundleID, category: "power.sleep")

    /// Issues `/usr/bin/pmset sleepnow`. Returns `false` if the tool could not
    /// be run or exited non-zero: the caller must notify on false, because a
    /// silent failure here is the data loss this project exists to prevent.
    public static func sleepNow() -> Bool {
        log.notice("pmset sleepnow")
        return PMSet.run(["sleepnow"]) != nil
    }
}
