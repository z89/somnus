//  SomnusCodeRequirement.swift
//  SomnusKit: shared signing requirements.
//
//  The code-signing requirement strings used by both ends of the XPC link.
//  The team identifier is read from the running binary's own signature because
//  every Somnus binary is signed by the same team.
//
//  `setCodeSigningRequirement` / `setConnectionCodeSigningRequirement` raise an
//  Objective-C exception on a malformed string, which is fatal in Swift. The
//  strings below are therefore assembled only from a whitelist-sanitised team
//  identifier and compile-time constants, and are `nil` (never malformed) when
//  the running binary is unsigned or ad-hoc signed.

import Foundation
import Security

public enum SomnusCodeRequirement {

    /// Team identifier (certificate `subject.OU`) of the currently running
    /// binary. `nil` for unsigned or ad-hoc-signed builds.
    private static let teamIdentifier: String? = Self.readOwnTeamIdentifier()

    /// Bundle identifiers of the three unprivileged clients, enumerated
    /// explicitly rather than using a `com.z89.somnus.*` wildcard: the wildcard
    /// form is untested and this form is verified.
    private static let clientIdentifiers = [
        SomnusConstants.appBundleID,
        SomnusConstants.appBundleID + ".SomnusControl",
        SomnusConstants.appBundleID + ".cli",
    ]

    /// Requirement a client applies to the daemon it connects to.
    /// Closes the "malicious process squats the Mach name" direction.
    public static let helper: String? = requirement(matching: [SomnusConstants.machServiceName])

    /// Requirement `somnusd`'s listener applies to incoming connections.
    public static let clients: String? = requirement(matching: clientIdentifiers)

    /// Builds `anchor apple generic and certificate leaf[subject.OU] = "TEAM"
    /// and (identifier "a" or identifier "b" ...)`.
    ///
    /// Deliberately does **not** pin an intermediate-certificate OID: pinning
    /// `6.2.1` would block a future notarised Developer ID release, and pinning
    /// `6.2.6` blocks every development build.
    private static func requirement(matching identifiers: [String]) -> String? {
        guard let team = teamIdentifier, !identifiers.isEmpty else { return nil }
        let ids = identifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(ids))"
    }

    // MARK: - Private

    private static func readOwnTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }

        guard let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return sanitised(team)
    }

    /// Requirement strings are never built from unvalidated text. Anything
    /// outside `[A-Z0-9]` means "not a team identifier": fail closed.
    private static func sanitised(_ team: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard !team.isEmpty,
              team.count <= 16,
              team.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return team
    }
}
