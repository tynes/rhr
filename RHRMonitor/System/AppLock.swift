import Foundation
import LocalAuthentication
import Observation

/// Optional Face ID / Touch ID / passcode lock for the app's screens (off by default).
///
/// Only the UI is locked. Bluetooth collection and recording keep running underneath, so a
/// locked app never loses data. Once enabled, the lock engages at launch and every time the app
/// goes to the background.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    /// Shown under the Settings toggle or on the lock screen when authentication fails.
    private(set) var lastError: String?

    private(set) var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Prompt once when the app comes back, not again after the user cancels a prompt
    /// (cancelling makes the app active again, which would otherwise re-prompt in a loop).
    @ObservationIgnored private var promptOnNextActivation: Bool
    private static let enabledKey = "appLockEnabled"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.isLocked = enabled
        self.promptOnNextActivation = enabled
    }

    /// "Face ID", "Touch ID", "Optic ID" or "passcode" (the lock needs a device passcode either way).
    nonisolated static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "passcode"
        }
    }

    /// Call when the app goes to the background.
    func lockIfEnabled() {
        guard isEnabled else { return }
        isLocked = true
        promptOnNextActivation = true
    }

    /// Call when the app becomes active: shows the Face ID / passcode prompt once after locking.
    func promptIfNeeded() async {
        guard isLocked, promptOnNextActivation else { return }
        promptOnNextActivation = false
        await unlock()
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        if await authenticate(reason: "Unlock RHR Monitor to see your heart rate data.") {
            isLocked = false
        }
    }

    /// Turning the lock on or off asks for authentication first, so it can't be switched off
    /// by someone who doesn't know the passcode, and so it's only enabled if it actually works.
    func setEnabled(_ on: Bool) async {
        guard on != isEnabled, !isAuthenticating else { return }
        let reason = on ? "Confirm to turn on the app lock." : "Confirm to turn off the app lock."
        if await authenticate(reason: reason) {
            isEnabled = on
            isLocked = false
        }
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = "Set a passcode for this iPhone (Settings › Face ID & Passcode) to use the app lock."
            return false
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            lastError = nil
            return ok
        } catch {
            let code = (error as? LAError)?.code
            let cancelled = code == .userCancel || code == .appCancel || code == .systemCancel
            lastError = cancelled ? nil : error.localizedDescription
            return false
        }
    }
}
