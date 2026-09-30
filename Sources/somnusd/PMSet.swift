//  PMSet.swift
//  somnusd: the only place in the daemon that spawns a subprocess.
//
//  SECURITY INVARIANTS (do not relax):
//    * `/usr/bin/pmset` is an absolute literal path. No PATH lookup, no shell,
//      no `sh -c`, no `Process.launchPath` from a variable.
//    * Arguments are FIXED literal arrays. The only caller-supplied value in the
//      whole daemon is a `Bool`, and it is mapped to the literal "0" or "1" by a
//      switch: never formatted, never interpolated.
//    * The child gets /dev/null on stdin, a two-entry environment built from
//      compile-time literals, and `/` as its working directory. It inherits
//      nothing from whoever launched somnusd.
//    * Nothing here caches. Every read is a fresh `pmset -g`.
//
//  `run` returns or throws within `worstCaseDuration`, including when a child
//  ignores SIGTERM. This keeps the helper's serial work queue available.

import Foundation
import SomnusKit

enum PMSet {

    /// Absolute, literal. Never assembled, never taken from the environment.
    static let executablePath = "/usr/bin/pmset"

    /// The child's entire environment. Built from compile-time literals so
    /// nothing reaches `pmset` from whatever environment launchd handed the
    /// daemon. `pmset` is invoked by absolute path and does not need `PATH`;
    /// it is present only because a process with no `PATH` at all is an
    /// unusual state that some libraries handle poorly.
    static let childEnvironment = ["PATH": "/usr/sbin:/usr/bin:/sbin:/bin"]

    /// `pmset` answers in milliseconds; anything beyond this is a wedged child
    /// and is sent SIGTERM so the XPC reply cannot hang forever.
    static let timeout: TimeInterval = 15

    /// A child that has not exited this long after SIGTERM is not going to.
    /// SIGKILL cannot be caught, blocked or ignored.
    static let killGrace: TimeInterval = 3

    /// After the child is gone, how long to wait for the pipe readers to hit
    /// EOF before giving up on its output and returning anyway.
    static let drainGrace: TimeInterval = 2

    /// Slack after SIGKILL before the child is declared unreapable. SIGKILL is
    /// delivered and acted on immediately unless the process is in an
    /// uninterruptible kernel wait, so this only has to cover scheduling.
    static let abandonGrace: TimeInterval = 1

    /// Hard upper bound on `run`. Past this the child is unreapable (SIGKILL
    /// does not dislodge a process in an uninterruptible kernel wait), so it is
    /// abandoned and the caller gets an error: the serial work queue must be
    /// released either way.
    static var worstCaseDuration: TimeInterval {
        timeout + killGrace + abandonGrace + drainGrace
    }

    struct Output {
        let standardOutput: String
    }

    // MARK: - The two privileged operations

    /// Fresh read of the system-wide `SleepDisabled` setting. Never cached.
    static func readSleepDisabled() throws -> Bool {
        let output = try run(["-g"])                       // FIXED argument array
        guard let value = parseSleepDisabled(output.standardOutput) else {
            throw SomnusError.pmsetFailed(
                status: -1,
                stderr: "pmset output did not contain readable power settings")
        }
        return value
    }

    /// Writes `disablesleep`, and nothing else. `hibernatemode` is never written.
    static func writeSleepDisabled(_ disabled: Bool) throws {
        // The Bool is mapped to a literal here. This switch is the complete
        // sanitisation story: no caller-supplied string ever reaches `Process`.
        let value: String
        switch disabled {
        case true:  value = "1"
        case false: value = "0"
        }
        _ = try run(["-a", "disablesleep", value])         // FIXED argument array

        // Exit status alone is not the postcondition. Read the system setting
        // back on the same serial daemon queue so a silent no-op can never be
        // reported to the app, widget or CLI as success.
        let applied = try readSleepDisabled()
        guard applied == disabled else {
            throw SomnusError.pmsetFailed(
                status: -1,
                stderr: "pmset exited successfully but SleepDisabled read back as \(applied ? 1 : 0)")
        }
    }

    // MARK: - Parsing

    /// `pmset -g` prints, under "System-wide power settings:", a line of the
    /// form " SleepDisabled\t\t1". The key is absent entirely on machines where
    /// it has never been set, and so is the whole section: `pmset` only prints
    /// it when at least one system-wide setting exists, so a fresh Mac starts
    /// straight at "Currently in use:".
    ///
    /// Returns `false` when the key is absent from otherwise valid output, which
    /// is how macOS represents the default. Malformed output returns `nil`.
    static func parseSleepDisabled(_ text: String) -> Bool? {
        guard text.contains("System-wide power settings:")
            || text.contains("Currently in use:") else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            let value = fields[1].lowercased()
            if value == "1" || value == "true" || value == "yes" { return true }
            if value == "0" || value == "false" || value == "no" { return false }
            return nil
        }
        return false
    }

    // MARK: - Subprocess

    /// Runs `/usr/bin/pmset` with `arguments` verbatim.
    ///
    /// Returns or throws within `worstCaseDuration`, always.
    ///
    /// - Throws: `SomnusError.pmsetFailed(status:stderr:)` if the tool cannot be
    ///   launched, is killed by the watchdog, is abandoned by the watchdog, or
    ///   exits non-zero.
    /// - Note: Callers run this on `SleepSettingHelper.workQueue` (serial), so
    ///   two `pmset` invocations never overlap.
    static func run(_ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // Assert the invariant the header claims, rather than merely stating it.
        process.environment = childEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Signalled from Foundation's own reaper thread. This, not
        // `waitUntilExit()`, is how the caller learns the child is gone -
        // `waitUntilExit()` has no timeout and is the second unbounded wait
        // that used to make this function un-exitable.
        let exited = DispatchSemaphore(value: 0)
        let watchdogFired = FlagBox()

        // Both watchdogs are declared before `run()` so the termination handler
        // can cancel them, and are scheduled only after a successful launch.
        let sigterm = DispatchWorkItem {
            guard process.isRunning else { return }
            watchdogFired.set()
            process.terminate()                            // SIGTERM
        }
        let sigkill = DispatchWorkItem {
            // `isRunning` reflects Process's own bookkeeping, not a probe of
            // the pid, and the item is cancelled from the termination handler,
            // so the signal cannot be delivered to a recycled pid in any
            // realistic interleaving.
            guard process.isRunning else { return }
            watchdogFired.set()
            kill(process.processIdentifier, SIGKILL)        // cannot be ignored
        }

        process.terminationHandler = { _ in
            sigterm.cancel()
            sigkill.cancel()
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw SomnusError.pmsetFailed(
                status: -1,
                stderr: "could not launch \(executablePath): \(error.localizedDescription)")
        }

        // Both pipes are drained on their own queues. Reading one to EOF before
        // touching the other can deadlock if the child fills the second pipe's
        // buffer; each `DataBox` is the only shared mutable state here and it is
        // internally locked.
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let readQueue = DispatchQueue.global(qos: .userInitiated)
        readQueue.async(group: group) {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
        }
        readQueue.async(group: group) {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
        }

        let watchdogQueue = DispatchQueue.global(qos: .utility)
        watchdogQueue.asyncAfter(deadline: .now() + timeout, execute: sigterm)
        watchdogQueue.asyncAfter(deadline: .now() + timeout + killGrace, execute: sigkill)

        // BOUNDED wait #1: the child. SIGKILL has already been sent by the time
        // this can expire, so reaching the timeout means the child is stuck in
        // an uninterruptible kernel wait and will never be reaped. Abandon it -
        // `terminationStatus` must not even be read on a process that has not
        // exited: and free the serial queue for the next caller.
        let childDeadline = DispatchTime.now() + (timeout + killGrace + abandonGrace)
        guard exited.wait(timeout: childDeadline) == .success else {
            sigterm.cancel()
            sigkill.cancel()
            throw SomnusError.pmsetFailed(
                status: -1,
                stderr: """
                    pmset did not exit within \(Int(timeout + killGrace))s, even after SIGTERM \
                    and SIGKILL, and has been abandoned
                    """)
        }
        sigterm.cancel()
        sigkill.cancel()

        // BOUNDED wait #2: the pipe readers. They hit EOF when the last copy of
        // the write end closes, which the child's death normally guarantees; the
        // timeout covers the case where it does not. A `DataBox` that has not
        // been filled simply reads as empty.
        _ = group.wait(timeout: .now() + drainGrace)

        let status = process.terminationStatus
        let standardError = errBox.string()
        guard status == 0, process.terminationReason == .exit else {
            let detail: String
            if watchdogFired.isSet {
                detail = "pmset exceeded \(Int(timeout))s and was killed by the somnus watchdog"
            } else if standardError.isEmpty {
                detail = "pmset did not exit cleanly (reason \(process.terminationReason.rawValue))"
            } else {
                detail = standardError
            }
            throw SomnusError.pmsetFailed(status: status, stderr: detail)
        }

        return Output(standardOutput: outBox.string())
    }
}

/// The pipe readers run on a concurrent global queue while the caller blocks on
/// the exit semaphore. `SWIFT_VERSION = 5.0` means the compiler will not police
/// this for us, so the hand-off is made explicit: every access is under the lock
/// and the caller only reads after `DispatchGroup.wait()`.
private final class DataBox {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) {
        lock.lock()
        data = newValue
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}

/// Set by the watchdog work items (on a global queue), read by the caller after
/// the child is gone. Same rationale as `DataBox`: explicit lock, because
/// `SWIFT_VERSION = 5.0` checks nothing.
private final class FlagBox {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }
}
