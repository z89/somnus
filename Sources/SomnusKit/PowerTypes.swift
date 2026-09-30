//  PowerTypes.swift
//  SomnusKit: shared power contracts. The memberwise initialisers are public so
//  the power engine can construct these and the preferences UI can build previews.

import Foundation

/// Read-only power snapshot. No privileges required to produce it.
public struct PowerFacts: Sendable, Equatable {
    public let batteryPercent: Int
    public let isOnAC: Bool
    public let isCharging: Bool
    /// From `IOPMrootDomain`'s `AppleClamshellState`. The property is absent on
    /// lidless Macs: producers must treat that as *unknown*, never as "open".
    public let lidClosed: Bool
    /// Read-only input to the safety-net preflight. somnus NEVER writes this.
    public let hibernateMode: Int
    public let sleepDisabled: Bool

    public init(batteryPercent: Int,
                isOnAC: Bool,
                isCharging: Bool,
                lidClosed: Bool,
                hibernateMode: Int,
                sleepDisabled: Bool) {
        self.batteryPercent = batteryPercent
        self.isOnAC = isOnAC
        self.isCharging = isCharging
        self.lidClosed = lidClosed
        self.hibernateMode = hibernateMode
        self.sleepDisabled = sleepDisabled
    }
}

public struct SleepAssertion: Sendable, Identifiable, Equatable {
    public let id: String
    public let pid: Int32
    public let processName: String
    /// e.g. "PreventUserIdleSystemSleep"
    public let type: String
    public let detail: String?

    public init(id: String,
                pid: Int32,
                processName: String,
                type: String,
                detail: String?) {
        self.id = id
        self.pid = pid
        self.processName = processName
        self.type = type
        self.detail = detail
    }
}

/// Implemented by the power engine and consumed by the preferences UI.
@MainActor public protocol PowerEngineObserving: AnyObject {
    var facts: PowerFacts? { get }
    var assertions: [SleepAssertion] { get }
    var acAwareModeEnabled: Bool { get set }
    var warnThreshold: Int { get set }   // default 20
    var actThreshold: Int { get set }    // default 10
    func refresh() async
}
