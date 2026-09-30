//  CLI.swift
//  somnus CLI: command dispatch.
//  Mode reads and writes use SomnusClient so the CLI and Control Center share
//  the same live source of truth.

import Foundation
import WidgetKit
import SomnusKit

enum ExitCode {
    static let ok: Int32          = 0
    /// somnusd could not be reached, or refused the operation.
    static let helper: Int32      = 2
    /// Something else failed: a `pmset -g assertions` read, say.
    static let failure: Int32     = 1
    /// Bad or missing subcommand. 64 is `EX_USAGE` from sysexits(3).
    static let usage: Int32       = 64
}

enum SomnusCLI {

    static func run(arguments: [String]) async -> Int32 {
        let arguments = Array(arguments.dropFirst())

        guard let command = arguments.first else {
            usage(to: FileHandle.standardError)
            return ExitCode.usage
        }

        let rest = Array(arguments.dropFirst())

        switch command {
        case "on" where rest.isEmpty:      return await set(true)
        case "off" where rest.isEmpty:     return await set(false)
        case "toggle" where rest.isEmpty:  return await toggle()
        case "status" where rest.isEmpty:  return await status()
        case "why" where rest.isEmpty:     return why()
        case "setup" where rest.isEmpty:
            return AppCommandBridge.run(["--somnus-setup"])
        case "setup" where rest == ["--repair"]:
            return AppCommandBridge.run(["--somnus-setup", "--repair-helper"])
        case "doctor" where rest.isEmpty:
            return AppCommandBridge.run(["--somnus-doctor"])
        case "help", "-h", "--help":   usage(to: FileHandle.standardOutput); return ExitCode.ok
        case "--version", "-v":        Output.line(version); return ExitCode.ok
        case "setup":
            Output.error("usage: somnus setup [--repair]")
            return ExitCode.usage
        default:
            if rest.isEmpty {
                Output.error("unknown command `\(command)`")
            } else {
                Output.error("`\(command)` takes no arguments (got \(rest.count))")
            }
            usage(to: FileHandle.standardError)
            return ExitCode.usage
        }
    }

    // MARK: - on / off / toggle

    private static func set(_ on: Bool) async -> Int32 {
        do {
            try await SomnusClient.shared.setStayAwake(on)
        } catch {
            Output.error(describe(SomnusError.from(error)))
            return ExitCode.helper
        }
        // The control re-reads on every render anyway, so this is a promptness
        // nicety, not a correctness crutch.
        ControlCenter.shared.reloadControls(ofKind: SomnusConstants.controlKind)
        Output.field("mode", modeName(on), style: modeStyle(on))
        return ExitCode.ok
    }

    private static func toggle() async -> Int32 {
        let current: Bool
        do {
            current = try await SomnusClient.shared.isStayAwakeOn()
        } catch {
            Output.error(describe(SomnusError.from(error)))
            return ExitCode.helper
        }
        return await set(!current)
    }

    // MARK: - status

    /// Fixed key set, always all of it, so a script can parse without caring
    /// which fields happened to be available. Unknowable values are the literal
    /// string `unknown`; inapplicable ones are `none`.
    private static func status() async -> Int32 {
        // Read first, and without the daemon: the battery half of `status` must
        // work whether or not somnusd is installed.
        let battery = BatteryFacts.read()

        // `nil` means "we could not find out", which is a third state and is
        // reported as such: never collapsed into "off".
        var isOn: Bool?
        var helper = "unreachable"
        var appRunning: Bool?
        var safetyNetArmed: Bool?
        var monitoringDegraded: Bool?
        var acAwareModeEnabled: Bool?
        var exitCode = ExitCode.ok

        do {
            isOn = try await SomnusClient.shared.isStayAwakeOn()
            helper = "ok"
        } catch {
            let somnusError = SomnusError.from(error)
            // Distinguishes "somnusd is not there" from "somnusd is there and
            // the read itself failed": different problems, different fixes.
            helper = await SomnusClient.shared.helperIsHealthy() ? "error" : "unreachable"
            Output.error(describe(somnusError))
            exitCode = ExitCode.helper
        }

        do {
            let control = try await SomnusClient.shared.controlStatus()
            appRunning = control.appRunning
            safetyNetArmed = control.safetyNetArmed
            monitoringDegraded = control.monitoringDegraded
            acAwareModeEnabled = control.acAwareModeEnabled
        } catch {
            Output.error("control status: \(describe(SomnusError.from(error)))")
            exitCode = ExitCode.helper
        }

        Output.field("mode", isOn.map(modeName) ?? "unknown", style: modeStyle(isOn))
        Output.field("sleep_disabled", isOn.map { $0 ? "1" : "0" } ?? "unknown")
        Output.field("helper", helper)
        Output.field("app_running", yesNoUnknown(appRunning))
        Output.field("safety_net_armed", yesNoUnknown(safetyNetArmed))
        Output.field("monitoring_degraded", yesNoUnknown(monitoringDegraded))
        Output.field("ac_aware_mode", yesNoUnknown(acAwareModeEnabled))
        Output.field("battery_percent", battery.percent.map(String.init) ?? "none")
        Output.field("power_source", battery.isOnAC ? "ac" : "battery")
        Output.field("charging", battery.isCharging ? "yes" : "no")
        Output.field("time_to_empty_minutes", battery.minutesToEmpty.map(String.init) ?? "unknown")
        Output.field("time_to_full_minutes", battery.minutesToFull.map(String.init) ?? "unknown")

        return exitCode
    }

    // MARK: - why

    private static func why() -> Int32 {
        let assertions: [SleepAssertion]
        do {
            assertions = try Assertions.read()
        } catch {
            Output.error(error.localizedDescription)
            return ExitCode.failure
        }

        guard !assertions.isEmpty else {
            Output.note("nothing is currently asserting against sleep")
            return ExitCode.ok
        }

        Output.table(assertions.map { assertion in
            [String(assertion.pid), assertion.processName, assertion.type, assertion.detail ?? "-"]
        }, headers: ["PID", "PROCESS", "TYPE", "DETAIL"])

        return ExitCode.ok
    }

    // MARK: - Presentation

    private static func modeName(_ on: Bool) -> String {
        on ? "stay-awake" : "normal-sleep"
    }

    private static func yesNoUnknown(_ value: Bool?) -> String {
        value.map { $0 ? "yes" : "no" } ?? "unknown"
    }

    /// Yellow for Stay Awake on purpose: it is the mode that can drain the
    /// battery to zero. Green is the mode that protects it. Red is "somnus
    /// does not know", which is never good news.
    private static func modeStyle(_ on: Bool?) -> (String) -> String {
        guard let on else { return Output.red }
        return on ? Output.yellow : Output.green
    }

    private static func describe(_ error: SomnusError) -> String {
        error.errorDescription ?? "the somnus helper could not be reached"
    }

    /// `"<CFBundleShortVersionString> (<CFBundleVersion>)"`, e.g. `"0.1.0 (1)"`.
    ///
    /// The SAME shape somnusd reports from `SomnusHelperProtocol.helperVersion`
    /// and the same shape `HelperInstallation.expectedHelperVersion` builds, so
    /// a support script can compare `somnus --version` against the helper's
    /// reported version directly. Printing the bare short version here made that
    /// comparison mismatch every single time.
    private static var version: String {
        SomnusConstants.version()
    }

    private static func usage(to handle: FileHandle) {
        let text = """
        somnus: a stateful Control Center toggle for macOS clamshell sleep

        usage: somnus <command>

          on       Stay Awake: the Mac keeps running with the lid closed
          off      Normal Sleep: the Mac sleeps normally
          toggle   flip between the two
          status   current mode plus battery, as `key: value` lines
          why      what is holding the Mac awake, as TAB-separated records:
                   pid, process, type, detail. Process-owned assertions only -
                   kernel assertions (a tethered iPhone, say) have no owning
                   process and are not listed here or in Preferences.
          setup    guide helper approval, notifications and Control Center;
                   add --repair after an update or version mismatch
          doctor   verify the installed app, helper, login item, warnings,
                   Control Center and live battery protection
          help     this text (also -h, --help)

          --version, -v   print the version and build

        exit codes:
          0   ok
          1   a read failed, or `setup` or `doctor` reported a problem
          2   somnusd could not be reached or refused the request: `status`
              still prints everything it could read without it
          64  usage error

        `status` and `why` need no privileges. `why`, and the battery half of
        `status`, work with somnusd absent; the mode does not, because reading it
        is a privileged round trip and somnus never caches state.

        ANSI colour and column padding are emitted only when stdout is a TTY.
        """
        handle.write(Data((text + "\n").utf8))
    }
}
