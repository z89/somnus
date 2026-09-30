//  main.swift
//  somnusd: the somnus root LaunchDaemon.
//
//  Demand-launched by launchd via the `MachServices` key in
//  Contents/Library/LaunchDaemons/com.z89.somnus.helper.plist (no KeepAlive, no
//  RunAtLoad). It advertises one Mach service and writes exactly one power
//  setting: `disablesleep`; its remaining methods expose in-memory health.
//
//  Argument vector is ignored on purpose: the daemon takes no options, so
//  there is nothing for a caller to influence.

import Foundation
import SomnusKit
import os

let bootLog = Logger(subsystem: SomnusConstants.machServiceName, category: "boot")

// Built once, at start-up, from the running binary's own signature. `nil` for an
// unsigned or ad-hoc-signed build: in which case the delegate below refuses
// every connection rather than serving root operations to an unauthenticated
// peer.
let clientRequirement = SomnusCodeRequirement.clients

let listener = NSXPCListener(machServiceName: SomnusConstants.machServiceName)

// The listener holds its delegate WEAKLY. These are top-level `let`s so both
// outlive the process; do not make them local to a function.
let helper = SleepSettingHelper()
let listenerDelegate = HelperListenerDelegate(clientRequirement: clientRequirement,
                                              helper: helper)
listener.delegate = listenerDelegate

if let clientRequirement {
    // Rejects non-matching peers before the delegate is consulted. The string is
    // well-formed by construction (SomnusCodeRequirement builds it from a
    // whitelist-sanitised team identifier plus compile-time constants); a
    // malformed one would raise an ObjC exception, which is fatal in Swift.
    listener.setConnectionCodeSigningRequirement(clientRequirement)
    bootLog.notice("somnusd \(SleepSettingHelper.version, privacy: .public) listening on \(SomnusConstants.machServiceName, privacy: .public)")
} else {
    // FAIL CLOSED: still bind, so clients get a clean refusal rather than a
    // squattable Mach name, but the delegate rejects every connection.
    bootLog.fault("""
        somnusd has no client code-signing requirement (unsigned or ad-hoc \
        signed binary). ALL connections will be refused.
        """)
}

listener.resume()
dispatchMain()
