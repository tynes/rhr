import Foundation

/// Sensor-contact status from the Heart Rate Measurement flags (bits 1–2).
public enum SensorContact: String, Codable, Sendable, CaseIterable {
    /// The sensor does not report contact status.
    case notSupported
    /// Contact is supported but not detected (e.g. strap off the wrist).
    case notDetected
    /// Contact is supported and detected.
    case detected
}

/// One decoded Bluetooth SIG Heart Rate Measurement (characteristic 0x2A37).
public struct HeartRateMeasurement: Equatable, Sendable {
    public var bpm: Int
    public var sensorContact: SensorContact
    /// Energy expended in kilojoules, when the sensor includes it.
    public var energyExpendedKJ: Int?
    /// RR intervals converted to milliseconds. Empty when the packet carries none.
    public var rrIntervalsMs: [Double]
    /// True when the packet ended with a single stray byte that could not form an RR interval.
    public var droppedTrailingByte: Bool

    public init(bpm: Int, sensorContact: SensorContact = .notSupported, energyExpendedKJ: Int? = nil,
                rrIntervalsMs: [Double] = [], droppedTrailingByte: Bool = false) {
        self.bpm = bpm
        self.sensorContact = sensorContact
        self.energyExpendedKJ = energyExpendedKJ
        self.rrIntervalsMs = rrIntervalsMs
        self.droppedTrailingByte = droppedTrailingByte
    }

    /// Whether the BPM value is inside the range we accept as physiological.
    public var isPlausible: Bool { HeartRateMeasurementParser.plausibleRange.contains(bpm) }
}

public enum HeartRateParseError: Error, Equatable, Sendable {
    case empty
    case truncatedHeartRate
    case truncatedEnergyExpended
}

/// Parser for the standard Heart Rate Measurement characteristic, written from the Bluetooth SIG
/// Heart Rate Service specification (HRS 1.0):
///
/// - byte 0 flags: bit 0 = HR value format (0 → UInt8, 1 → UInt16 little-endian);
///   bits 1–2 = sensor contact status; bit 3 = Energy Expended present (UInt16 kJ);
///   bit 4 = one or more RR intervals present (UInt16, units of 1/1024 s).
///
/// No sampling interval is assumed, and RR intervals are optional.
public enum HeartRateMeasurementParser {
    /// BPM values outside this range are treated as invalid (0 is commonly sent when off-wrist).
    public static let plausibleRange = 25...250

    /// Milliseconds per RR tick (1/1024 s). Exactly representable in binary floating point.
    public static let msPerRRTick = 1000.0 / 1024.0

    public static func parse(_ data: Data) throws -> HeartRateMeasurement {
        try parse([UInt8](data))
    }

    public static func parse(_ bytes: [UInt8]) throws -> HeartRateMeasurement {
        guard let flags = bytes.first else { throw HeartRateParseError.empty }
        let is16Bit = flags & 0x01 != 0
        let contactSupported = flags & 0x04 != 0
        let contactDetected = flags & 0x02 != 0
        let hasEnergy = flags & 0x08 != 0
        let hasRR = flags & 0x10 != 0

        var index = 1
        let bpm: Int
        if is16Bit {
            guard bytes.count >= index + 2 else { throw HeartRateParseError.truncatedHeartRate }
            bpm = Int(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
        } else {
            guard bytes.count >= index + 1 else { throw HeartRateParseError.truncatedHeartRate }
            bpm = Int(bytes[index])
            index += 1
        }

        var energy: Int?
        if hasEnergy {
            guard bytes.count >= index + 2 else { throw HeartRateParseError.truncatedEnergyExpended }
            energy = Int(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
        }

        var rr: [Double] = []
        var dropped = false
        if hasRR {
            while index + 1 < bytes.count {
                let raw = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                rr.append(Double(raw) * msPerRRTick)
                index += 2
            }
            // A lone trailing byte cannot be an RR interval; keep the HR and drop the fragment.
            if index < bytes.count { dropped = true }
        }

        let contact: SensorContact = contactSupported ? (contactDetected ? .detected : .notDetected) : .notSupported
        return HeartRateMeasurement(bpm: bpm, sensorContact: contact, energyExpendedKJ: energy,
                                    rrIntervalsMs: rr, droppedTrailingByte: dropped)
    }
}
