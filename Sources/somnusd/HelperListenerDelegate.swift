//  HelperListenerDelegate.swift
//  somnusd: connection admission control.
//
//  Three gates, in this order:
//
//   1. The listener's code-signing requirement
//      (`NSXPCListener.setConnectionCodeSigningRequirement`, macOS 13+). A peer
//      that does not match is rejected by XPC itself, BEFORE this delegate is
//      ever consulted (see NSXPCConnection.h). This is the primary check
//      and the expected admission rule for the daemon.
//
//   2. This delegate's requirement check, which FAILS CLOSED.
//      `SomnusCodeRequirement.clients` is `nil` whenever the running binary is
//      unsigned or ad-hoc signed: the requirement string is deliberately never
//      guessed, because a malformed one raises an Objective-C exception that is
//      fatal in Swift. When it is `nil` NO requirement could be installed on
//      the listener, so gate 1 does not exist, and every single connection is
//      refused here instead. There is no path through this file that accepts a
//      connection while `clientRequirement == nil`.
//
//   3. The PRINCIPAL check, below. Gates 1 and 2 authenticate *code*; they say
//      nothing about *who is running it*. `MachServices` in a LaunchDaemon
//      plist registers the name in the SYSTEM bootstrap namespace, which is
//      reachable from every uid on the machine. So once an admin approves
//      somnus, any local account: a standard non-admin user, a
//      fast-user-switched background session, or malware running as any of
//      them: could run the shipped, correctly signed CLI and set
//      `SleepDisabled` system-wide and permanently. Outside somnus that takes
//      `sudo pmset -a disablesleep 1`. So the peer's effective uid must be
//      either 0 (the CLI legitimately run under `sudo`) or the current console
//      user (the app, the widget, and the CLI run normally by the person
//      actually sitting at the machine).
//
//      This is defence in depth ON TOP OF gates 1 and 2, never instead of
//      them: a peer must pass all three.
//
//  Audit tokens are deliberately NOT used: `NSXPCConnection.auditToken` is SPI
//  and PID-based `SecCode` lookups are vulnerable to PID reuse, so
//  `processIdentifier` is never used for a security decision here. `effectiveUserIdentifier` IS used, but only as gate 3, and
//  only to narrow what gates 1 and 2 have already authenticated: it is a
//  documented admission-control property (see NSXPCConnection.h) and,
//  unlike a pid, it cannot be recycled onto a different principal mid-flight.

import Foundation
import SomnusKit
import SystemConfiguration
import os

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    /// The requirement string that was installed on the listener, or `nil` if
    /// none could be built. Immutable for the lifetime of the daemon: the
    /// admission decision can never be flipped at runtime.
    let clientRequirement: String?

    /// The single exported object. Stateless and shared by every connection.
    private let helper: SleepSettingHelper

    private let log = Logger(subsystem: SomnusConstants.machServiceName, category: "xpc")

    init(clientRequirement: String?, helper: SleepSettingHelper) {
        self.clientRequirement = clientRequirement
        self.helper = helper
    }

    /// Called on the listener's private serial queue.
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

        // GATE 2: FAIL CLOSED. No requirement means no way to authenticate the
        // peer, and an unauthenticated peer must never reach a root daemon.
        guard clientRequirement != nil else {
            log.fault("""
                refusing connection: no client code-signing requirement is \
                available (somnusd is unsigned or ad-hoc signed). Every \
                connection is rejected.
                """)
            return false
        }

        // GATE 3: PRINCIPAL. Reaching here means the peer is somnus code; it
        // does not mean the peer is the person using this Mac.
        guard accepts(principalOf: newConnection) else { return false }

        // Reaching here means XPC already matched the peer against the
        // requirement installed on the listener. The requirement is NOT applied
        // a second time via `NSXPCConnection.setCodeSigningRequirement`: the
        // header states it is an XPC error to set a connection's requirement
        // more than once, and the listener has already set it for us.
        newConnection.exportedInterface = .somnusHelper
        newConnection.exportedObject = helper
        newConnection.resume()
        return true
    }

    // MARK: - Principal check

    /// Accepts uid 0, or the uid of the current console user. Everything else
    /// is refused, including the case where the console user cannot be
    /// determined at all: that is the fail-closed branch, and it is reached
    /// at the login window, in a screen-locked-with-no-session state, and if
    /// SystemConfiguration answers with anything unexpected.
    ///
    /// Evaluated once, at connection time. A client that connects while it owns
    /// the console keeps its connection across a later fast user switch; that
    /// matches how every other console-gated macOS service behaves and does not
    /// let a *new* background principal in.
    private func accepts(principalOf connection: NSXPCConnection) -> Bool {
        accepts(peerUID: connection.effectiveUserIdentifier,
                consoleUser: Self.consoleUserID())
    }

    /// The whole decision, as a pure function of the two uids, so it can be
    /// exercised directly for every case including the ones that cannot be
    /// staged on a developer's machine (a second logged-in account).
    /// `consoleUser == nil` is the fail-closed input and must reject anything
    /// that is not root.
    ///
    /// Internal rather than private only so that table can be tested.
    func accepts(peerUID peer: uid_t, consoleUser: uid_t?) -> Bool {
        // The CLI may legitimately be run under `sudo`, which is why uid is not
        // used as the *only* gate: but "root" is still a principal somnus is
        // willing to serve.
        if peer == 0 { return true }

        guard let console = consoleUser else {
            log.error("""
                refusing connection from uid \(peer, privacy: .public): no \
                console user could be determined, so the peer cannot be shown \
                to be the person using this Mac.
                """)
            return false
        }

        guard peer == console else {
            log.error("""
                refusing connection from uid \(peer, privacy: .public): not \
                root and not the console user (uid \(console, privacy: .public)).
                """)
            return false
        }

        return true
    }

    /// uid of the user currently owning the console, or `nil` when there is
    /// none. `nil` is the fail-closed answer and callers must treat it as
    /// "reject", never as "allow".
    ///
    /// `SCDynamicStoreCopyConsoleUser` reports `"loginwindow"` when no user is
    /// at the console; that, an empty name, and uid 0 are all rejected here so
    /// the only way this returns a value is a real, logged-in, non-root
    /// console session.
    static func consoleUserID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else { return nil }
        let user = name as String
        guard !user.isEmpty, user != "loginwindow", uid != 0 else { return nil }
        return uid
    }
}
