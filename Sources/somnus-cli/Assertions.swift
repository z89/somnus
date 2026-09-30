//  Assertions.swift
//  somnus CLI: `somnus why`.
//
//  Runs `pmset -g assertions` and hands the text to SomnusKit's
//  `SleepAssertionParser`, which is also used by the preferences inspector.
//
//  This is a READ. somnus never writes power settings from the CLI: every
//  write goes through SomnusClient to somnusd. `pmset` is invoked with a fixed
//  argument array via Process: never a shell string, never interpolation of
//  anything the caller typed.

import Foundation
import SomnusKit

enum Assertions {

    enum ReadError: Error, LocalizedError {
        case launchFailed(String)
        case exited(Int32)
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .launchFailed(reason): return "could not run /usr/bin/pmset: \(reason)"
            case let .exited(status):       return "pmset -g assertions exited with status \(status)"
            case .timedOut:                 return "pmset -g assertions did not finish within 10 seconds"
            }
        }
    }

    /// Every process-owned assertion currently holding the Mac awake, in the
    /// order pmset lists it. Kernel assertions are excluded: see the note in
    /// `SomnusKit/SleepAssertionParser.swift`; `somnus why`'s usage text says so.
    static func read() throws -> [SleepAssertion] {
        SleepAssertionParser.parse(try runPmsetAssertions())
    }

    // MARK: - Running pmset

    private static func runPmsetAssertions() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]

        let output = Pipe()
        process.standardOutput = output
        // Discarded on purpose: draining two pipes from one thread can deadlock,
        // and the exit status is a sufficient diagnostic for a read-only query.
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
            throw ReadError.launchFailed(error.localizedDescription)
        }

        DispatchQueue.global(qos: .utility).async {
            data.set(output.fileHandleForReading.readDataToEndOfFile())
            outputRead.signal()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10,
                                                       execute: terminate)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12,
                                                       execute: forceTerminate)

        guard exited.wait(timeout: .now() + 13) == .success else {
            terminate.cancel()
            forceTerminate.cancel()
            throw ReadError.timedOut
        }
        _ = outputRead.wait(timeout: .now() + 1)

        guard process.terminationStatus == 0 else {
            throw ReadError.exited(process.terminationStatus)
        }
        return String(decoding: data.snapshot(), as: UTF8.self)
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
