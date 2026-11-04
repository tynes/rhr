import UIKit
import Observation
import HeartRateKit

/// Owns `UIApplication.isIdleTimerDisabled`.
///
/// Each window scene reports whether it needs the screen awake (Keep Screen Awake is on,
/// monitoring is active, the scene is in the foreground and a monitoring screen is visible).
/// Auto-lock is disabled while any scene asks for it and restored as soon as none do.
@MainActor
@Observable
final class KeepAwakeController {
    private var arbiter = KeepAwakeArbiter()
    /// True while the idle timer is disabled by this app.
    private(set) var isActive = false

    func update(scene: String, wantsAwake: Bool) {
        let disabled = arbiter.set(scene, wantsAwake: wantsAwake)
        if UIApplication.shared.isIdleTimerDisabled != disabled {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
        isActive = disabled
    }

    func releaseAll() {
        arbiter = KeepAwakeArbiter()
        UIApplication.shared.isIdleTimerDisabled = false
        isActive = false
    }
}
