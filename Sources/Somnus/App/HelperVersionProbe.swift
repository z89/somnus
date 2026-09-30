//  HelperVersionProbe.swift
//  Somnus: helper version probe.
//
//  Asks the running daemon which version it is, so the app can detect the
//  version skew after an app update: the
//  SMAppService must be re-registered or the daemon may not launch.
//
//  This uses a short-lived independent connection rather than SomnusClient's
//  shared power connection because it belongs to installation-state probing.
//  It applies the identical code-signing requirement, so it authenticates the
//  daemon exactly as strictly.
//
//  It is used only for the *installation* status display. Nothing about the
//  Stay Awake state is read or cached here.

import Foundation
import SomnusKit

enum HelperVersionProbe {

    /// How long to wait before deciding the daemon is not answering. A
    /// registered-but-never-bootstrapped daemon is precisely the failure this
    /// probe exists to surface, so it must not be able to hang the UI.
    private static let timeout: TimeInterval = 3

    /// The version string the running daemon reports, or `nil` if it is not
    /// installed, not approved, or not answering. Never throws: an unreachable
    /// daemon is information, not an error.
    static func currentVersion() async -> String? {
        // Fail closed: without a well-formed requirement we would be talking to
        // an unauthenticated root daemon. Refuse instead.
        guard let requirement = SomnusCodeRequirement.helper else { return nil }

        let connection = NSXPCConnection(machServiceName: SomnusConstants.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface = .somnusHelper
        connection.setCodeSigningRequirement(requirement)
        connection.resume()

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let box = SingleShot(continuation: continuation)

            // The error handler and the reply block are both eligible to fire;
            // the box lets exactly one of them through.
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                box.finish(nil)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.finish(nil)
            }

            guard let helper = proxy as? SomnusHelperProtocol else {
                box.finish(nil)
                return
            }
            helper.helperVersion { version in
                box.finish(version)
            }
        }

        connection.invalidate()
        return result
    }
}

/// Resuming a continuation twice traps. This lets the first caller win.
private final class SingleShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
