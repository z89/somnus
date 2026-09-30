//  HelperInstallation.swift
//  Somnus: helper and login-item installation.
//
//  ServiceManagement can throw EPERM after a successful first registration.
//  Registration decisions therefore use the status read after each operation;
//  an error is retained only to explain a status that did not advance.

import Foundation
import Observation
import ServiceManagement
import SomnusKit
import WidgetKit

// MARK: - ServiceManagement error codes

/// The `SMError` enum in `SMErrors.h` is unnamed and **starts at 2**. Code 1 is
/// therefore not one of its members; it is POSIX `EPERM` surfaced in
/// `SMAppServiceErrorDomain`. Branch on the numeric code, never the domain
/// string: the domain has historically also been reported as
/// `NSOSStatusErrorDomain`.
enum SMErrorCode: Int {
    /// NOT an `SMError`. Raw POSIX EPERM. Expected, and benign, on a first
    /// successful `register()`; only meaningful when `status` did not move.
    case operationNotPermitted  = 1
    case internalFailure        = 2
    case invalidSignature       = 3
    case authorizationFailure   = 4
    case toolNotValid           = 5
    case jobNotFound            = 6
    case serviceUnavailable     = 7
    case jobPlistNotFound       = 8
    case jobMustBeEnabled       = 9
    case invalidPlist           = 10
    case launchDeniedByUser     = 11
    case alreadyRegistered      = 12
}

// MARK: - What the user is shown

/// Every `SMAppService.Status` maps onto exactly one of these, plus the decoded
/// failures that can leave the status at `.notRegistered`.
enum HelperState: Equatable {
    /// Nothing read yet (first paint only).
    case unknown
    /// `.notRegistered`: never installed, or uninstalled.
    case notInstalled
    /// `.requiresApproval`: registered, waiting on an admin in System Settings.
    case awaitingApproval
    /// `kSMErrorLaunchDeniedByUser (11)`: actively declined or revoked.
    case declinedByUser
    /// `kSMErrorJobMustBeEnabled (9)`: switched off in Login Items & Extensions.
    case disabledInSystemSettings
    /// `.enabled`: approved, bootstrapped, serving XPC.
    case installed
    /// `.notFound` after a registration attempt, or a plist/executable error:
    /// the app bundle itself is wrong.
    case bundleBroken(reason: String)
    /// Anything else, with the decoded code kept so bug reports are useful.
    case failed(code: Int, message: String)
    /// A `Status` case added after macOS 26. Never silently treated as working.
    case unrecognisedStatus(rawValue: Int)

    /// One short line, for the menu bar.
    var summary: String {
        switch self {
        case .unknown:                  return "Helper: checking…"
        case .notInstalled:             return "Helper: not installed"
        case .awaitingApproval:         return "Helper: needs approval"
        case .declinedByUser:           return "Helper: declined"
        case .disabledInSystemSettings: return "Helper: switched off"
        case .installed:                return "Helper: ready"
        case .bundleBroken:             return "Helper: broken install"
        case .failed:                   return "Helper: failed"
        case .unrecognisedStatus:       return "Helper: unknown state"
        }
    }

    var title: String {
        switch self {
        case .unknown:                  return "Checking the helper…"
        case .notInstalled:             return "Helper not installed"
        case .awaitingApproval:         return "Waiting for your approval"
        case .declinedByUser:           return "Helper was declined"
        case .disabledInSystemSettings: return "Helper is switched off"
        case .installed:                return "Helper installed and approved"
        case .bundleBroken:             return "This copy of somnus is incomplete"
        case .failed:                   return "Helper installation failed"
        case .unrecognisedStatus:       return "Helper is in an unrecognised state"
        }
    }

    /// What the user should do about it, in plain words.
    var guidance: String {
        switch self {
        case .unknown:
            return "Reading the current registration status."
        case .notInstalled:
            return """
            somnus cannot change the sleep setting until its helper is installed. \
            Installing registers a launchd daemon; macOS will then ask an administrator \
            to approve it in System Settings.
            """
        case .awaitingApproval:
            return """
            The helper is registered but macOS will not start it until an administrator \
            approves it. Open System Settings → General → Login Items & Extensions, find \
            somnus, and switch it on. macOS reports "never approved" and "approved, then \
            revoked" identically, so if you approved it before, check that it has not been \
            switched back off.
            """
        case .declinedByUser:
            return """
            Approval for the helper was declined or revoked. Allow somnus in \
            System Settings → General → Login Items & Extensions, then choose Install again.
            """
        case .disabledInSystemSettings:
            return """
            The helper is registered but disabled in System Settings → General → \
            Login Items & Extensions. Switch it back on there.
            """
        case .installed:
            return "Stay Awake can be changed from Control Center, the somnus command, or Shortcuts."
        case let .bundleBroken(reason):
            return """
            \(reason) Reinstalling somnus is the fix: approving it in System Settings will not help. \
            Rebuild the app, or copy a complete Somnus.app into /Applications.
            """
        case let .failed(code, message):
            return "\(message) (ServiceManagement code \(code).)"
        case let .unrecognisedStatus(rawValue):
            return """
            macOS reported registration status \(rawValue), which this version of somnus does not \
            recognise. Treating it as not working rather than guessing.
            """
        }
    }

    var symbolName: String {
        switch self {
        case .installed:                            return "checkmark.seal.fill"
        case .awaitingApproval, .declinedByUser,
             .disabledInSystemSettings:             return "exclamationmark.triangle.fill"
        case .unknown, .notInstalled:               return "circle.dashed"
        case .bundleBroken, .failed,
             .unrecognisedStatus:                   return "xmark.octagon.fill"
        }
    }

    /// `true` only when the daemon is genuinely eligible to run.
    var isOperational: Bool {
        if case .installed = self { return true }
        return false
    }

    /// States whose fix lives in System Settings → Login Items & Extensions.
    var wantsSystemSettings: Bool {
        switch self {
        case .awaitingApproval, .declinedByUser, .disabledInSystemSettings: return true
        default:                                                           return false
        }
    }

    /// States where pressing Install is worth something.
    var canInstall: Bool {
        switch self {
        case .installed, .unknown: return false
        default:                   return true
        }
    }

    /// Registration exists (or might), so unregistering is meaningful.
    var canUninstall: Bool {
        switch self {
        case .unknown, .notInstalled: return false
        default:                      return true
        }
    }

    /// A stale registration can report "already registered" while presenting
    /// as not registered. That contradiction is specifically repairable.
    var repairSuggested: Bool {
        guard case let .failed(code, _) = self else { return false }
        return code == SMErrorCode.alreadyRegistered.rawValue
    }
}

/// `SMAppService.mainApp`: somnus as its own login item.
enum LoginItemState: Equatable {
    case unknown
    case disabled
    case awaitingApproval
    case enabled
    case problem(String)

    /// What the toggle should show: registration was requested, even when
    /// macOS is still waiting for approval.
    var isRequested: Bool {
        switch self {
        case .enabled, .awaitingApproval: return true
        default:                          return false
        }
    }

    /// Only `.enabled` proves the safety net will return after login.
    var isOperational: Bool { self == .enabled }

    var problemDescription: String? {
        guard case let .problem(message) = self else { return nil }
        return message
    }

    var detail: String {
        switch self {
        case .unknown:
            return "Checking whether somnus starts at login."
        case .disabled:
            return """
            somnus is not set to open at login. The battery safety net only runs while somnus \
            is running: with this off, nothing turns Stay Awake off at the low-battery threshold.
            """
        case .awaitingApproval:
            return """
            macOS is waiting for you to allow somnus in System Settings → General → \
            Login Items & Extensions. Until then it will not start at login.
            """
        case .enabled:
            return "somnus starts at login, so the battery safety net is armed after a restart."
        case let .problem(message):
            return message
        }
    }
}

// MARK: - The installation model

@MainActor
@Observable
final class HelperInstallation {

    static let shared = HelperInstallation()

    private(set) var state: HelperState = .unknown
    private(set) var loginItem: LoginItemState = .unknown

    /// Version string the *running* daemon reports over XPC, or `nil` if it did
    /// not answer. Meaningful only once `versionCheckCompleted` is `true`.
    private(set) var reportedHelperVersion: String?
    private(set) var versionCheckCompleted = false

    /// Result of the most recent action, when it is worth saying out loud.
    private(set) var lastMessage: String?
    private(set) var serviceOperationInProgress = false

    private let service = SMAppService.daemon(plistName: SomnusConstants.helperPlistName)
    private let loginItemService = SMAppService.mainApp

    private init() {}

    // MARK: Version skew

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The version string an up-to-date helper reports.
    var expectedHelperVersion: String {
        SomnusConstants.version()
    }

    /// `true` when an approved daemon is running an older build of the helper.
    /// Apple's header is explicit: after an app update the service **must** be
    /// re-registered or it may not launch, and `unregister()` before
    /// `register()` is recommended when the executable changed.
    ///
    /// Advisory only. A stale helper still works: it is merely out of date -
    /// so this offers Repair and never blocks, and never re-registers by itself
    /// (that would put a System Settings approval prompt in the user's face).
    var hasVersionSkew: Bool {
        guard state.isOperational, versionCheckCompleted,
              let reported = reportedHelperVersion else { return false }
        return reported != expectedHelperVersion
    }

    /// Approved and supposedly enabled, yet not answering XPC: the other half
    /// of the version-skew problem: a stale registration that never launched.
    var helperUnreachable: Bool {
        state.isOperational && versionCheckCompleted && reportedHelperVersion == nil
    }

    var canRepair: Bool {
        hasVersionSkew || helperUnreachable || state.repairSuggested
    }

    /// `true` when somnus has no working path to `SleepDisabled`: the helper is
    /// missing, unapproved, switched off, broken, or approved but not answering.
    ///
    /// On its own this is merely an installation problem. Combined with a Stay
    /// Awake that is *on* it is the dangerous state: the Mac cannot sleep, the
    /// safety net cannot save it, and only `sudo pmset -a disablesleep 0` can.
    /// Every caller that pairs the two must show `StayAwakeRecovery.command`.
    var cannotChangeStayAwake: Bool {
        if serviceOperationInProgress { return true }
        if state == .unknown { return false }   // nothing read yet; do not cry wolf
        return !state.isOperational || helperUnreachable
    }

    // MARK: Reading

    /// Cheap and synchronous: `status` is a plain property. Safe to call on a
    /// timer or whenever the preferences window comes forward.
    func refresh() {
        let previousState = state
        state = Self.state(forStatus: service.status, lastError: nil,
                           registrationAttempted: false)
        loginItem = Self.loginItemState(forStatus: loginItemService.status)
        if state != previousState { reloadControlAfterServiceChange() }
    }

    /// Asks the running daemon which version it is. Never throws: an
    /// unreachable daemon is information, not an error.
    func checkHelperVersion() async {
        guard state.isOperational else {
            reportedHelperVersion = nil
            versionCheckCompleted = false
            return
        }
        reportedHelperVersion = await HelperVersionProbe.currentVersion()
        versionCheckCompleted = true
    }

    // MARK: Actions

    /// Idempotent. Registers the daemon and makes somnus its own login item,
    /// because the safety net is inert unless both are true.
    func install() {
        lastMessage = nil
        registerDaemon()
        setLoginItemEnabled(true)
        reloadControlAfterServiceChange()
    }

    /// After an app update. `unregister()` first, per the header's explicit
    /// recommendation when the executable has changed.
    @discardableResult
    func repairRegistration() async -> Bool {
        lastMessage = nil

        guard !serviceOperationInProgress else {
            lastMessage = "A helper operation is already in progress."
            return false
        }
        serviceOperationInProgress = true

        // The ordinary menu-bar process can otherwise run AC-aware policy or a
        // heartbeat while its service is being replaced. One-shot terminal
        // commands never construct either singleton.
        let runningAsMenuBarApp = SomnusTerminalCommand.current == nil
        if runningAsMenuBarApp {
            PowerEngine.shared.stop()
            await AppStatusHeartbeat.shared.stop()
        }
        defer {
            serviceOperationInProgress = false
            if runningAsMenuBarApp {
                PowerEngine.shared.start()
                AppStatusHeartbeat.shared.start()
            }
        }

        // Unregistering is the one repair step that can remove the only process
        // able to clear persistent SleepDisabled. Refuse unless an independent
        // read proves Normal Sleep first. The installer already disarms updates;
        // direct CLI and GUI repairs now fail closed as well.
        guard await StayAwakeDisarm.currentlyOn() == false else {
            lastMessage = """
            Repair was not started because Normal Sleep could not be verified. Turn Stay Awake \
            off, confirm the mode is Normal Sleep, then choose Repair again. If somnus cannot \
            turn it off, run `\(StayAwakeRecovery.command)` in Terminal.
            """
            refresh()
            return false
        }

        await SomnusClient.shared.disconnect()

        do {
            // The synchronous overload returns before launchd has reaped the
            // running daemon. Apple's completion-handler contract explicitly
            // says re-registration is safe only after that handler fires; the
            // Swift async import gives us that exact boundary.
            try await service.unregister()
        } catch {
            let nsError = error as NSError
            if nsError.code != SMErrorCode.jobNotFound.rawValue {
                state = Self.state(forStatus: service.status,
                                   lastError: nsError,
                                   registrationAttempted: false)
                lastMessage = "The old helper could not be stopped before repair: \(Self.describe(nsError))"
                reloadControlAfterServiceChange()
                return false
            }
        }

        // ServiceManagement's completion is the documented re-registration
        // boundary, but Background Task Management can still report its old
        // record briefly afterward. Retry only this finite update operation;
        // ordinary app state is never polled this way.
        registration: for attempt in 0..<20 {
            var thrown: NSError?
            do {
                try service.register()
            } catch {
                thrown = error as NSError
            }

            // ⛔ Status, not the throw. Re-registration EPERMs exactly like a first one.
            state = Self.state(forStatus: service.status, lastError: thrown,
                               registrationAttempted: true)
            switch state {
            case .installed, .awaitingApproval:
                break registration
            default:
                if attempt < 19 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        reportedHelperVersion = nil
        versionCheckCompleted = false
        if state.isOperational {
            lastMessage = "Helper re-registered."
        } else if state == .awaitingApproval {
            // Re-registration drops the helper back into "needs approval", and
            // until an administrator approves it somnus cannot write
            // SleepDisabled at all. Normal Sleep was verified before repair.
            lastMessage = """
            Helper re-registered and Normal Sleep is on. Approve it in System Settings before \
            trying to turn Stay Awake on again.
            """
        } else {
            // The helper was unregistered to re-register it and the second half
            // failed. The preflight keeps this safe even with no helper left.
            lastMessage = """
            Normal Sleep was verified first, but helper re-registration failed. Stay Awake is \
            safely off. Reinstall somnus or run `somnus setup --repair` to try again.
            """
        }
        reloadControlAfterServiceChange()
        return state.isOperational || state == .awaitingApproval
    }

    /// A helper transition invalidates status connections in the control
    /// extension. Reload now, then once more after XPC teardown has settled.
    private func reloadControlAfterServiceChange() {
        ControlCenter.shared.reloadControls(ofKind: SomnusConstants.controlKind)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            ControlCenter.shared.reloadControls(ofKind: SomnusConstants.controlKind)
        }
    }

    /// The plan's undo path depends on this. Removes the daemon registration
    /// and the login item; no root-owned files are left behind.
    ///
    /// ⛔ ORDERING IS THE WHOLE POINT. Stay Awake is turned off **before**
    /// `unregister()`, because after unregistering there is nothing left that
    /// can write `SleepDisabled`: the daemon is the only thing with the
    /// privilege, and it has just been removed. Unregistering first would leave
    /// the Mac unable to sleep on a closed lid, on battery, with the battery
    /// safety net gone as well, and nothing in somnus able to undo it. That is
    /// leaving persistent Stay Awake state without battery protection.
    ///
    /// If the disarm fails, this returns **without** unregistering. Leaving the
    /// helper installed is recoverable; unregistering it while Stay Awake is on
    /// is not, other than by hand in Terminal.
    @discardableResult
    func uninstall() async -> Bool {
        lastMessage = nil

        guard !serviceOperationInProgress else {
            lastMessage = "A helper operation is already in progress."
            return false
        }
        serviceOperationInProgress = true

        let runningAsMenuBarApp = SomnusTerminalCommand.current == nil
        if runningAsMenuBarApp {
            PowerEngine.shared.stop()
            await AppStatusHeartbeat.shared.stop()
        }
        defer {
            serviceOperationInProgress = false
            if runningAsMenuBarApp {
                PowerEngine.shared.start()
                AppStatusHeartbeat.shared.start()
            }
        }

        switch await StayAwakeDisarm.disarm() {
        case .notNeeded, .disarmed:
            break                            // safe to dismantle

        case let .failed(reason):
            // Do NOT fall through to unregister(). Say what is true and stop.
            lastMessage = StayAwakeRecovery.strandedMessage("""
                somnus has NOT been uninstalled. Stay Awake is on and somnus could not turn it \
                off (\(reason)), so the helper has been left registered on purpose: \
                unregistering it now would leave your Mac unable to sleep with nothing able to \
                change it back.

                Turn Stay Awake off first (from Control Center, the somnus command, or the \
                command below), then choose Uninstall again.
                """)
            refresh()
            return false
        }

        await SomnusClient.shared.disconnect()
        let failures = await unregisterServices()

        // The status is authoritative because unregister() can report an error
        // after the service has already been removed.
        state = Self.state(forStatus: service.status, lastError: failures.daemon,
                           registrationAttempted: false)
        loginItem = Self.loginItemState(forStatus: loginItemService.status)
        reportedHelperVersion = nil
        versionCheckCompleted = false
        let normalSleepVerified = await StayAwakeDisarm.currentlyOn() == false

        if !normalSleepVerified {
            lastMessage = StayAwakeRecovery.strandedMessage("""
                Service removal finished, but the final independent read could not verify Normal \
                Sleep. Somnus.app has been left in place so its recovery instructions remain \
                available.
                """)
        } else if state.isOperational {
            let detail = failures.daemon.map(Self.describe) ?? "macOS still reports it as enabled"
            lastMessage = """
            Stay Awake was turned off first, so your Mac can sleep normally. macOS then refused \
            to unregister the helper (\(detail)). It is still registered.
            """
        } else if loginItem.isRequested {
            let detail = failures.loginItem.map(Self.describe) ?? "macOS still reports it as enabled"
            lastMessage = """
            Stay Awake is off and the helper is unregistered, but the login item could not be \
            removed (\(detail)). Disable Somnus in Login Items & Extensions.
            """
        } else if let problem = loginItem.problemDescription {
            lastMessage = """
            Stay Awake is off and the helper is unregistered. The login item could not be \
            verified: \(problem)
            """
        } else {
            // Honest about the two things it cannot do: delete the app for the
            // user, and help them once it is gone.
            lastMessage = """
            Stay Awake is off and the helper is unregistered. No root-owned files are left \
            behind. somnus cannot delete Somnus.app for you: delete Somnus.app to finish \
            removing somnus.

            From here on nothing in somnus can change Stay Awake. If it is ever left on with no \
            helper installed, this clears it from Terminal:

                \(StayAwakeRecovery.command)
            """
        }
        return normalSleepVerified && state == .notInstalled && loginItem == .disabled
    }

    /// Unregisters both services after Stay Awake has been disarmed. The async
    /// completion is the point at which ServiceManagement says teardown ended.
    private struct UnregisterFailures {
        var daemon: NSError?
        var loginItem: NSError?
    }

    private func unregisterServices() async -> UnregisterFailures {
        var daemonFailure: NSError?
        var loginItemFailure: NSError?

        do {
            try await service.unregister()
        } catch {
            let nsError = error as NSError
            // kSMErrorJobNotFound (6) means it was already gone: success.
            if nsError.code != SMErrorCode.jobNotFound.rawValue {
                daemonFailure = nsError
            }
        }

        do {
            try await loginItemService.unregister()
        } catch {
            let nsError = error as NSError
            if nsError.code != SMErrorCode.jobNotFound.rawValue {
                loginItemFailure = nsError
            }
        }

        return UnregisterFailures(daemon: daemonFailure,
                                  loginItem: loginItemFailure)
    }

    func setLoginItemEnabled(_ enabled: Bool) {
        if enabled {
            switch loginItemService.status {
            case .enabled, .requiresApproval:
                break                       // already done; register() would only churn
            case .notRegistered, .notFound:
                // register() may throw EPERM here too: the status read below decides.
                try? loginItemService.register()
            @unknown default:
                try? loginItemService.register()
            }
        } else {
            try? loginItemService.unregister()
        }
        loginItem = Self.loginItemState(forStatus: loginItemService.status)
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Registration

    private func registerDaemon() {
        // 1. Branch on status BEFORE doing anything. `.enabled` and
        //    `.requiresApproval` are already-registered states; calling
        //    register() again only invites kSMErrorAlreadyRegistered.
        switch service.status {
        case .enabled:
            state = .installed
            return
        case .requiresApproval:
            state = .awaitingApproval
            return
        case .notFound, .notRegistered:
            // On a pristine machine ServiceManagement can report `.notFound`
            // simply because no BTM record exists yet, even when the embedded
            // plist and executable are valid. Registration is what creates
            // that record. Only treat `.notFound` as a broken bundle if it is
            // still the status after `register()` has been attempted.
            break
        @unknown default:
            state = .unrecognisedStatus(rawValue: service.status.rawValue)
            return
        }

        var thrown: NSError?
        do {
            try service.register()
        } catch {
            // ⛔ DO NOT return here. A first successful registration lands in
            //    this branch with EPERM (code 1) and IS registered.
            thrown = error as NSError
        }

        // 2. Re-read the status. It, and only it, decides the outcome.
        state = Self.state(forStatus: service.status, lastError: thrown,
                           registrationAttempted: true)

        if state == .awaitingApproval {
            lastMessage = """
            Helper registered. macOS needs an administrator to approve it in \
            System Settings before it can run.
            """
        }
    }

    // MARK: Status → state

    /// The single mapping from `SMAppService.Status` to what the user sees.
    /// `lastError` is consulted **only** when the status says the registration
    /// did not take, and then purely to explain why.
    private static func state(forStatus status: SMAppService.Status,
                              lastError: NSError?,
                              registrationAttempted: Bool) -> HelperState {
        switch status {
        case .enabled:
            return .installed

        case .requiresApproval:
            return .awaitingApproval

        case .notFound:
            guard registrationAttempted else { return .notInstalled }
            return .bundleBroken(reason: """
                macOS cannot find the helper's launchd job, which means \
                Contents/Library/LaunchDaemons/\(SomnusConstants.helperPlistName) is missing \
                from the app bundle.
                """)

        case .notRegistered:
            guard let lastError else { return .notInstalled }
            return diagnosis(for: lastError)

        @unknown default:
            return .unrecognisedStatus(rawValue: status.rawValue)
        }
    }

    private static func loginItemState(forStatus status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled:          return .enabled
        case .requiresApproval: return .awaitingApproval
        case .notRegistered:    return .disabled
        case .notFound:         return .problem("""
            macOS cannot find this app's login-item registration. Move Somnus.app to \
            /Applications and open it again.
            """)
        @unknown default:       return .problem("""
            macOS reported login-item status \(status.rawValue), which this version of somnus \
            does not recognise.
            """)
        }
    }

    /// Decodes a `register()` failure that genuinely left the status at
    /// `.notRegistered`. Every documented ServiceManagement code appears here.
    private static func diagnosis(for error: NSError) -> HelperState {
        switch SMErrorCode(rawValue: error.code) {
        case .operationNotPermitted:
            // On a *successful* first registration this same code is thrown and
            // the status moves to .requiresApproval, so we never reach here in
            // that case. Reaching it means the registration really was refused.
            return .failed(code: error.code, message: """
                macOS refused the registration and the helper is still not registered. \
                LaunchDaemons are only bootstrapped reliably from /Applications: move \
                Somnus.app there and try again.
                """)

        case .internalFailure:
            return .failed(code: error.code,
                           message: "ServiceManagement hit an internal failure. Try again.")

        case .invalidSignature:
            return .failed(code: error.code, message: """
                The app bundle's code signature was rejected. An ad-hoc or broken signature, \
                or a bundle modified after signing, will do this: rebuild and re-sign somnus.
                """)

        case .authorizationFailure:
            return .failed(code: error.code,
                           message: "macOS declined to authorise the registration.")

        case .toolNotValid:
            return .bundleBroken(reason: """
                The helper executable named by the daemon plist's BundleProgram key is missing \
                or is not runnable.
                """)

        case .jobNotFound:
            return .notInstalled

        case .serviceUnavailable:
            return .failed(code: error.code, message: """
                launchd is not accepting requests at the moment. Try again in a few seconds.
                """)

        case .jobPlistNotFound:
            return .bundleBroken(reason: """
                There is no launchd plist at \
                Contents/Library/LaunchDaemons/\(SomnusConstants.helperPlistName).
                """)

        case .jobMustBeEnabled:
            return .disabledInSystemSettings

        case .invalidPlist:
            return .bundleBroken(reason: "The helper's launchd plist is malformed.")

        case .launchDeniedByUser:
            return .declinedByUser

        case .alreadyRegistered:
            // Contradiction: launchd says registered, status says not. A stale
            // registration from an older copy of the app does exactly this.
            return .failed(code: error.code, message: """
                macOS reports the helper as already registered while its status says it is not. \
                Choose Repair to unregister and register it again.
                """)

        case nil:
            return .failed(code: error.code, message: describe(error))
        }
    }

    private static func describe(_ error: NSError) -> String {
        let description = error.localizedDescription
        return description.isEmpty ? "ServiceManagement error \(error.code)." : description
    }
}
