//  SomnusConstants.swift
//  SomnusKit: shared constants. Do not rename public identifiers casually.

import Foundation

public enum SomnusConstants {
    /// The Mach service name advertised by somnusd's LaunchDaemon plist.
    public static let machServiceName = "com.z89.somnus.helper"

    /// File name (not path) of the launchd plist, as passed to
    /// `SMAppService.daemon(plistName:)`.
    public static let helperPlistName = "com.z89.somnus.helper.plist"

    /// Bundle identifier of the containing app.
    public static let appBundleID = "com.z89.somnus"

    /// Kind string for the Control Center control. Must be identical in
    /// `StaticControlConfiguration(kind:)` and in every
    /// `ControlCenter.shared.reloadControls(ofKind:)` call.
    ///
    /// Kept in SomnusKit so every target shares one constant.
    public static let controlKind = "com.z89.somnus.StayAwake"

    /// Payload-free Darwin notification posted only after somnusd has written
    /// `SleepDisabled` and independently read the requested value back. The
    /// app observes this as an edge trigger, then re-reads the system setting;
    /// the notification is never treated as state in its own right.
    public static let stayAwakeDidChangeNotification =
        "com.z89.somnus.stay-awake-did-change"

    /// Safe-direction hint emitted after an explicit/user-policy OFF succeeds.
    /// A spoof can only cancel an automatic restore, never enable Stay Awake.
    public static let manualOffIntentNotification =
        "com.z89.somnus.manual-off-intent"

    /// Version format shared by the app, helper, and command-line tool.
    public static func version(in bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "0"
        return "\(short) (\(build))"
    }
}
