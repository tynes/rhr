import Foundation

/// One persisted heart rate notification. Timestamps are when the phone received the
/// notification (millisecond precision, UTC); the strap does not timestamp 0x2A37 packets.
public struct HeartRateSample: Equatable, Sendable, Codable {
    public var id: Int64?
    public var sessionID: String
    public var timestamp: Date
    public var bpm: Int
    public var rrIntervalsMs: [Double]
    public var sensorContact: SensorContact
    public var sourceDevice: String

    public init(id: Int64? = nil, sessionID: String, timestamp: Date, bpm: Int, rrIntervalsMs: [Double] = [],
                sensorContact: SensorContact = .notSupported, sourceDevice: String) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = ISOTimestamp.truncated(timestamp)
        self.bpm = bpm
        self.rrIntervalsMs = rrIntervalsMs
        self.sensorContact = sensorContact
        self.sourceDevice = sourceDevice
    }

    public var timestampMs: Int64 { ISOTimestamp.milliseconds(timestamp) }
    public var point: HeartRatePoint { HeartRatePoint(timestamp: timestamp, bpm: bpm) }
}

/// Minimal (time, bpm) pair used by charts and analytics.
public struct HeartRatePoint: Equatable, Sendable, Codable {
    public var timestamp: Date
    public var bpm: Int
    public init(timestamp: Date, bpm: Int) {
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    /// Currently recording (or was when the app last ran).
    case recording
    /// Stopped by the user.
    case completed
    /// Ended because the app was terminated or the session could not be resumed.
    case interrupted
}

public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case freeform
    case resting
}

public struct RecordingSession: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var deviceIdentifier: String?
    public var deviceName: String?
    public var sampleCount: Int
    public var status: SessionStatus
    public var kind: SessionKind
    public var notes: String

    public init(id: String = UUID().uuidString, startedAt: Date, endedAt: Date? = nil, deviceIdentifier: String? = nil,
                deviceName: String? = nil, sampleCount: Int = 0, status: SessionStatus = .recording,
                kind: SessionKind = .freeform, notes: String = "") {
        self.id = id
        self.startedAt = ISOTimestamp.truncated(startedAt)
        self.endedAt = endedAt.map(ISOTimestamp.truncated)
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.sampleCount = sampleCount
        self.status = status
        self.kind = kind
        self.notes = notes
    }

    public func duration(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }
}

public enum Posture: String, Codable, Sendable, CaseIterable, Identifiable {
    case sitting
    case lyingDown
    public var id: String { rawValue }
    public var label: String { self == .sitting ? "Sitting" : "Lying down" }
}

/// A connection-level event (connect, disconnect, Bluetooth off…), kept so gaps can be explained.
public struct ConnectionEvent: Equatable, Sendable, Codable {
    public var id: Int64?
    public var sessionID: String?
    public var timestamp: Date
    public var kind: String
    public var detail: String

    public init(id: Int64? = nil, sessionID: String?, timestamp: Date, kind: String, detail: String = "") {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = ISOTimestamp.truncated(timestamp)
        self.kind = kind
        self.detail = detail
    }
}
