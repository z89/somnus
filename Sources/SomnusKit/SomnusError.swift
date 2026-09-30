//  SomnusError.swift
//  SomnusKit: shared error contract. The NSError bridging below is needed
//  because a Swift enum cannot cross NSXPC, so somnusd returns
//  `SomnusError.pmsetFailed(...).asNSError` and the client decodes it with
//  `SomnusError.from(_:)`.

import Foundation

public enum SomnusError: Error, Sendable {
    case helperNotInstalled
    case helperVersionMismatch(expected: String, found: String)
    case connectionRefused
    case pmsetFailed(status: Int32, stderr: String)
    case safetyNetUnavailable
}

// MARK: - NSError bridging

extension SomnusError: CustomNSError, LocalizedError {

    public static let errorDomain = "com.z89.somnus.error"

    /// Stable numeric codes. Do not renumber: they travel over XPC.
    public enum Code: Int, Sendable {
        case helperNotInstalled     = 1
        case helperVersionMismatch  = 2
        case connectionRefused      = 3
        case pmsetFailed            = 4
        case safetyNetUnavailable   = 5
    }

    enum UserInfoKey {
        static let expected = "SomnusExpectedVersion"
        static let found    = "SomnusFoundVersion"
        static let status   = "SomnusExitStatus"
        static let stderr   = "SomnusStandardError"
    }

    public var errorCode: Int {
        switch self {
        case .helperNotInstalled:    return Code.helperNotInstalled.rawValue
        case .helperVersionMismatch: return Code.helperVersionMismatch.rawValue
        case .connectionRefused:     return Code.connectionRefused.rawValue
        case .pmsetFailed:           return Code.pmsetFailed.rawValue
        case .safetyNetUnavailable:  return Code.safetyNetUnavailable.rawValue
        }
    }

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "somnus error"]
        switch self {
        case .helperNotInstalled, .connectionRefused, .safetyNetUnavailable:
            break
        case let .helperVersionMismatch(expected, found):
            info[UserInfoKey.expected] = expected
            info[UserInfoKey.found] = found
        case let .pmsetFailed(status, stderr):
            info[UserInfoKey.status] = Int(status)
            info[UserInfoKey.stderr] = stderr
        }
        return info
    }

    public var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return "The somnus helper is not installed, has not been approved yet, or its signature does not match this build."
        case let .helperVersionMismatch(expected, found):
            return "The somnus helper is version \(found) but the app expects \(expected)."
        case .connectionRefused:
            return "The somnus helper refused the connection or did not answer in time."
        case .safetyNetUnavailable:
            return "Stay Awake cannot be turned on until the Somnus app is running and its battery safety net is armed."
        case let .pmsetFailed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "pmset exited with status \(status)."
                : "pmset exited with status \(status): \(detail)"
        }
    }

    /// An `NSError` carrying this case, suitable for returning across NSXPC.
    public var asNSError: NSError {
        NSError(domain: Self.errorDomain, code: errorCode, userInfo: errorUserInfo)
    }

    /// Recovers a `SomnusError` from anything that came back over XPC.
    /// Non-somnus errors (connection invalidated, interrupted, code-signing
    /// requirement failures) are mapped onto the closest somnus case.
    public static func from(_ error: Error) -> SomnusError {
        if let somnus = error as? SomnusError { return somnus }
        let ns = error as NSError

        if ns.domain == errorDomain {
            switch Code(rawValue: ns.code) {
            case .helperNotInstalled:
                return .helperNotInstalled
            case .helperVersionMismatch:
                return .helperVersionMismatch(
                    expected: ns.userInfo[UserInfoKey.expected] as? String ?? "",
                    found: ns.userInfo[UserInfoKey.found] as? String ?? "")
            case .connectionRefused:
                return .connectionRefused
            case .pmsetFailed:
                return .pmsetFailed(
                    status: Int32(ns.userInfo[UserInfoKey.status] as? Int ?? -1),
                    stderr: ns.userInfo[UserInfoKey.stderr] as? String ?? "")
            case .safetyNetUnavailable:
                return .safetyNetUnavailable
            case nil:
                return .connectionRefused
            }
        }

        // NSXPCConnection failures arrive in NSCocoaErrorDomain.
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case CocoaError.Code.xpcConnectionInvalid.rawValue:
                // launchd has no such service: the daemon was never approved,
                // or has been unregistered.
                return .helperNotInstalled
            default:
                return .connectionRefused
            }
        }

        return .connectionRefused
    }
}
