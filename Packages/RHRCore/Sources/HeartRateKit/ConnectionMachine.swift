import Foundation

/// Bluetooth radio / permission availability, mirroring CBManagerState without importing CoreBluetooth.
public enum BluetoothAvailability: String, Equatable, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

    public var userMessage: String {
        switch self {
        case .unknown: return "Checking Bluetooth…"
        case .resetting: return "Bluetooth is restarting."
        case .unsupported: return "This device does not support Bluetooth Low Energy."
        case .unauthorized: return "Bluetooth permission was denied. Enable it in Settings › Privacy › Bluetooth."
        case .poweredOff: return "Bluetooth is turned off."
        case .poweredOn: return "Bluetooth is on."
        }
    }
}

/// User-visible connection phase: disconnected → scanning → connecting → connected → reconnecting.
public enum ConnectionPhase: Equatable, Sendable {
    case unavailable(BluetoothAvailability)
    case disconnected
    case scanning
    case connecting
    case connected
    case reconnecting

    public var label: String {
        switch self {
        case .unavailable(let a): return a == .unknown ? "Starting" : "Bluetooth unavailable"
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        }
    }
}

/// Pure connection state machine. The CoreBluetooth layer feeds it events and performs the
/// returned effects, which keeps reconnection policy unit-testable.
public struct ConnectionMachine: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case bluetooth(BluetoothAvailability)
        case startScan
        case stopScan
        /// The user picked a device (or a remembered device is being reconnected).
        case connect
        case didConnect
        /// Heart rate notifications are enabled.
        case subscribed
        case didFailToConnect
        case didDisconnect
        case userDisconnect
        /// The device lacks the Heart Rate service — retrying will not help.
        case serviceMissing
        /// Forget the selected device entirely.
        case forget
    }

    public enum Effect: Equatable, Sendable {
        case startScan
        case stopScan
        case connectPeripheral
        /// Retry a connection after a back-off delay (seconds).
        case scheduleReconnect(after: TimeInterval)
        case cancelPeripheral
        case discoverServices
    }

    public private(set) var phase: ConnectionPhase = .unavailable(.unknown)
    public private(set) var bluetooth: BluetoothAvailability = .unknown
    /// The user wants to stay connected to the selected device; drives automatic reconnection.
    public private(set) var wantsConnection = false
    public private(set) var hasPeripheral = false
    public private(set) var failedAttempts = 0

    public init() {}

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .bluetooth(let state):
            bluetooth = state
            guard state == .poweredOn else {
                // CoreBluetooth drops links and pending connects when the radio goes away.
                phase = .unavailable(state)
                return []
            }
            if wantsConnection && hasPeripheral {
                phase = .reconnecting
                return [.connectPeripheral]
            }
            phase = .disconnected
            return []

        case .startScan:
            guard bluetooth == .poweredOn else { return [] }
            if phase == .connected || phase == .connecting { return [.startScan] }
            phase = .scanning
            return [.startScan]

        case .stopScan:
            if phase == .scanning { phase = .disconnected }
            return [.stopScan]

        case .connect:
            wantsConnection = true
            hasPeripheral = true
            failedAttempts = 0
            guard bluetooth == .poweredOn else { return [] }
            phase = .connecting
            return [.stopScan, .connectPeripheral]

        case .didConnect:
            failedAttempts = 0
            if phase != .reconnecting { phase = .connecting }
            return [.discoverServices]

        case .subscribed:
            phase = .connected
            return []

        case .didFailToConnect:
            guard wantsConnection, bluetooth == .poweredOn else {
                phase = bluetooth == .poweredOn ? .disconnected : .unavailable(bluetooth)
                return []
            }
            failedAttempts += 1
            phase = .reconnecting
            let delay = min(30, pow(2, Double(min(failedAttempts, 5))))
            return [.scheduleReconnect(after: delay)]

        case .didDisconnect:
            guard bluetooth == .poweredOn else { phase = .unavailable(bluetooth); return [] }
            guard wantsConnection else { phase = .disconnected; return [] }
            // An iOS pending connect never times out, so issuing it immediately is the
            // battery-friendly way to reconnect when the strap comes back into range.
            phase = .reconnecting
            return [.connectPeripheral]

        case .userDisconnect:
            wantsConnection = false
            if bluetooth == .poweredOn { phase = .disconnected }
            return [.cancelPeripheral]

        case .serviceMissing:
            wantsConnection = false
            phase = bluetooth == .poweredOn ? .disconnected : .unavailable(bluetooth)
            return [.cancelPeripheral]

        case .forget:
            wantsConnection = false
            hasPeripheral = false
            if bluetooth == .poweredOn { phase = .disconnected }
            return [.cancelPeripheral]
        }
    }
}

/// Whether the displayed reading is live.
public enum ReadingFreshness: Equatable, Sendable {
    case none
    case live
    case stale(age: TimeInterval)

    /// Readings older than this are shown as stale.
    public static let staleAfter: TimeInterval = 5

    public static func evaluate(lastSampleAt: Date?, now: Date, staleAfter: TimeInterval = staleAfter) -> ReadingFreshness {
        guard let last = lastSampleAt else { return .none }
        let age = max(0, now.timeIntervalSince(last))
        return age <= staleAfter ? .live : .stale(age: age)
    }
}

/// Decides whether the screen's idle timer should be disabled.
///
/// Each scene reports whether it currently needs the screen awake; the idle timer stays
/// disabled while *any* scene does, so closing one window never re-enables auto-lock for another.
public struct KeepAwakeArbiter: Equatable, Sendable {
    public private(set) var requesters: Set<String> = []

    public init() {}

    public var idleTimerDisabled: Bool { !requesters.isEmpty }

    /// Updates one scene's request; returns the resulting `isIdleTimerDisabled` value.
    @discardableResult
    public mutating func set(_ scene: String, wantsAwake: Bool) -> Bool {
        if wantsAwake { requesters.insert(scene) } else { requesters.remove(scene) }
        return idleTimerDisabled
    }

    /// Whether one scene should hold the screen awake.
    ///
    /// - userEnabled: the Keep Screen Awake toggle.
    /// - monitoringActive: recording, or connected/reconnecting to a heart rate device.
    /// - sceneActive: the scene is in the foreground (`ScenePhase.active`).
    /// - monitorVisible: a monitoring screen (Live or Resting) is on screen.
    public static func sceneWantsAwake(userEnabled: Bool, monitoringActive: Bool, sceneActive: Bool,
                                       monitorVisible: Bool) -> Bool {
        userEnabled && monitoringActive && sceneActive && monitorVisible
    }
}
