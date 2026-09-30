//  StayAwakeRecovery.swift
//  Somnus: safe Stay Awake recovery.
//
//  Stay Awake is persistent system state. Any path that removes Somnus must
//  turn it off first or give the user the command that clears it manually.

import AppKit
import Foundation
import SomnusKit

// MARK: - The words

/// Every user-facing string about "Stay Awake is on and somnus cannot fix it"
/// is built from these pieces, so none of them can drift apart or quietly lose
/// the recovery command.
enum StayAwakeRecovery {

    /// The literal command that clears `SleepDisabled` with no somnus involved.
    /// Deliberately a plain constant so it can be shown, copied and grepped for.
    static let command = "sudo pmset -a disablesleep 0"

    /// Why a stranded Stay Awake value must be treated as persistent system
    /// state even though the installed helper normally self-heals it.
    static let persistenceExplanation = """
        Stay Awake is not a somnus setting. It is macOS's own SleepDisabled flag, stored in \
        /Library/Preferences/SystemConfiguration/com.apple.PowerManagement.plist. The installed \
        helper normally clears it if the battery guardian disappears. If the helper is unavailable, \
        however, the flag can outlive the app and a restart. While it remains on your Mac will not \
        sleep when you close the lid, even on battery, and can eventually lose power.
        """

    /// The escape hatch, always including the literal command.
    static let terminalInstruction = """
        This command clears it from Terminal, with or without somnus installed:

            \(command)
        """

    /// Situation → the full explanation, guaranteed to carry the command.
    static func strandedMessage(_ situation: String) -> String {
        """
        \(situation)

        \(persistenceExplanation)

        \(terminalInstruction)
        """
    }

    /// Short enough for a menu item, and still contains the command verbatim.
    static let copyCommandButtonTitle = "Copy \"\(command)\""

    /// Writing the pasteboard is only ever done in response to the user asking.
    static func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }
}

// MARK: - Turning it off before somnus goes away

/// Reads the live Stay Awake state and turns it off. Used by the uninstall path
/// and the quit path: the two ways somnus stops being able to help.
enum StayAwakeDisarm {

    enum Outcome: Equatable {
        /// Already off. Nothing to do, and nothing to warn about.
        case notNeeded
        /// It was on; it is now off, confirmed by a second, independent read.
        case disarmed
        /// It is (or may still be) on and somnus could not change it.
        case failed(reason: String)
    }

    /// `true`/`false` from a fresh unprivileged read, or `nil` when the state
    /// could not be determined at all.
    ///
    /// `pmset -g` requires no privileges, so this still answers when the helper
    /// is unregistered, unapproved or dead: which is precisely when the answer
    /// matters most. Reading it directly also keeps one-shot uninstall mode
    /// from starting the whole battery engine. XPC is the fallback.
    @MainActor
    static func currentlyOn() async -> Bool? {
        let settings = await Task.detached(priority: .userInitiated) {
            PMSet.readSleepSettings()
        }.value
        if settings.sleepDisabledIsKnown {
            return settings.sleepDisabled
        }
        return try? await SomnusClient.shared.isStayAwakeOn()
    }

    /// Turns Stay Awake off if it is on, and verifies it actually went off.
    ///
    /// Fails closed throughout: an unreadable state is treated as "on", and an
    /// unverifiable write is treated as a failure. Being wrong in that direction
    /// costs a warning the user did not need; being wrong in the other direction
    /// costs their tabs.
    @MainActor
    static func disarm() async -> Outcome {
        if await currentlyOn() == false { return .notNeeded }

        do {
            // The stable SomnusClient contract: returns only once somnusd has
            // confirmed `pmset -a disablesleep 0` applied.
            try await SomnusClient.shared.setStayAwake(false)
        } catch {
            return .failed(reason: error.localizedDescription)
        }

        // Do not take the write's word for it. Re-read, unprivileged.
        if await currentlyOn() != false {
            return .failed(reason: """
                the helper reported success but macOS still reports Stay Awake as on
                """)
        }
        return .disarmed
    }
}
