//  AppCommandBridge.swift
//  Runs setup-only operations through the containing Somnus.app.

import Foundation
import Darwin

enum AppCommandBridge {

    static func run(_ arguments: [String]) -> Int32 {
        guard let executable = appExecutable else {
            Output.error("could not find the Somnus.app containing this command")
            Output.note("reinstall with ./scripts/install.sh, then try again")
            return ExitCode.failure
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
            // Guided setup can legitimately wait while the user approves a
            // macOS pane, but a wedged app must not hold the CLI forever.
            if finished.wait(timeout: .now() + 11 * 60) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 5) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 2)
                }
                Output.error("Somnus.app did not finish within 11 minutes")
                return ExitCode.failure
            }
            return process.terminationReason == .exit
                ? process.terminationStatus
                : ExitCode.failure
        } catch {
            Output.error("could not start Somnus.app: \(error.localizedDescription)")
            return ExitCode.failure
        }
    }

    /// Resolve `/usr/local/bin/somnus`, then walk upward from the real embedded
    /// CLI. This also works when invoked directly from Contents/Helpers.
    ///
    /// `Bundle.main.executableURL` is the path the kernel executed.
    /// `CommandLine.arguments[0]` is not: a shell passes the bare word
    /// `somnus` for a PATH lookup, which would resolve against the current
    /// directory instead.
    private static var appExecutable: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        var cursor = executable
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .deletingLastPathComponent()

        while cursor.path != "/" {
            if cursor.pathExtension == "app" {
                let executable = cursor.appendingPathComponent("Contents/MacOS/Somnus")
                return FileManager.default.isExecutableFile(atPath: executable.path)
                    ? executable
                    : nil
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }
}
