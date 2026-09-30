//  SomnusHelperProtocol.swift
//  SomnusKit: the complete root-helper contract. Power writes remain limited
//  to `setSleepDisabled`; monitoring status is process-local metadata only.

import Foundation

/// The only privileged operations in somnus. Implemented by somnusd (root);
/// consumed by the widget, app and CLI over XPC.
@objc public protocol SomnusHelperProtocol {
    func getSleepDisabled(reply: @escaping (Bool, Error?) -> Void)
    func setSleepDisabled(_ enabled: Bool, reply: @escaping (Error?) -> Void)
    func helperVersion(reply: @escaping (String) -> Void)
    func getControlStatus(reply: @escaping (Bool, Bool, Bool, Bool, Bool, Error?) -> Void)
    func reportAppStatus(_ running: Bool,
                         safetyNetArmed: Bool,
                         monitoringDegraded: Bool,
                         acAwareModeEnabled: Bool,
                         reply: @escaping (Error?) -> Void)
}

/// One truthful snapshot for Control Center. `appRunning` is based on a bounded
/// heartbeat, not on whether the privileged helper happens to be reachable.
public struct SomnusControlStatus: Equatable, Sendable {
    public let stayAwakeOn: Bool
    public let appRunning: Bool
    public let safetyNetArmed: Bool
    public let monitoringDegraded: Bool
    public let acAwareModeEnabled: Bool

    public init(stayAwakeOn: Bool,
                appRunning: Bool,
                safetyNetArmed: Bool,
                monitoringDegraded: Bool,
                acAwareModeEnabled: Bool) {
        self.stayAwakeOn = stayAwakeOn
        self.appRunning = appRunning
        self.safetyNetArmed = safetyNetArmed
        self.monitoringDegraded = monitoringDegraded
        self.acAwareModeEnabled = acAwareModeEnabled
    }
}

public extension NSXPCInterface {
    /// The interface every somnus XPC endpoint uses, in one place so the daemon
    /// and the clients cannot drift apart.
    static var somnusHelper: NSXPCInterface {
        NSXPCInterface(with: SomnusHelperProtocol.self)
    }
}
