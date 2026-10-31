import Foundation
import Observation

/// User preferences stored in UserDefaults (no health data is stored here).
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Keep Screen Awake. Deliberately not persisted: it starts OFF on every launch.
    var keepScreenAwake = false

    var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: Keys.autoReconnect) }
    }

    var selectedDeviceID: String? {
        didSet { defaults.set(selectedDeviceID, forKey: Keys.deviceID) }
    }

    var selectedDeviceName: String? {
        didSet { defaults.set(selectedDeviceName, forKey: Keys.deviceName) }
    }

    /// Minimum window coverage for a valid resting measurement (0.5…1.0).
    var restingMinimumCoverage: Double {
        didSet { defaults.set(restingMinimumCoverage, forKey: Keys.minCoverage) }
    }

    /// Feed a synthetic heart rate stream instead of Bluetooth (for testing without a strap).
    var simulatedHeartRate: Bool {
        didSet { defaults.set(simulatedHeartRate, forKey: Keys.simulated) }
    }

    /// Posture of an in-progress resting measurement, keyed by session, so it survives app termination.
    func setPendingPosture(_ posture: String?, sessionID: String) {
        defaults.set(posture, forKey: "pendingPosture.\(sessionID)")
    }

    func pendingPosture(sessionID: String) -> String? {
        defaults.string(forKey: "pendingPosture.\(sessionID)")
    }

    private enum Keys {
        static let autoReconnect = "autoReconnect"
        static let deviceID = "selectedDeviceID"
        static let deviceName = "selectedDeviceName"
        static let minCoverage = "restingMinimumCoverage"
        static let simulated = "simulatedHeartRate"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.autoReconnect: true, Keys.minCoverage: 0.8, Keys.simulated: false])
        autoReconnect = defaults.bool(forKey: Keys.autoReconnect)
        selectedDeviceID = defaults.string(forKey: Keys.deviceID)
        selectedDeviceName = defaults.string(forKey: Keys.deviceName)
        restingMinimumCoverage = defaults.double(forKey: Keys.minCoverage)
        simulatedHeartRate = defaults.bool(forKey: Keys.simulated)
    }
}
