import Foundation

/// CSV and JSON export.
///
/// Conventions (also documented in docs/DATA_FORMAT.md):
/// - Timestamps are ISO 8601 UTC with milliseconds (`2026-10-31T08:29:00.123Z`), plus a
///   `*_unix_ms` column with the same instant as integer milliseconds.
/// - Calendar days (`day`) are local dates (`yyyy-MM-dd`) in the time zone where the value was
///   measured; `time_zone` gives that zone for resting measurements.
/// - Heart rate in beats per minute; RR intervals in milliseconds (1/1024 s resolution),
///   separated by `;` inside one field.
public enum CSVExporter {
    public static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static func row(_ fields: [String]) -> String { fields.map(escape).joined(separator: ",") }

    static func number(_ d: Double?) -> String {
        guard let d else { return "" }
        return "\(d)"
    }

    static func fixed(_ d: Double?, _ places: Int = 2) -> String {
        guard let d else { return "" }
        return String(format: "%.\(places)f", d)
    }

    public static let samplesHeader = ["session_id", "timestamp_utc", "timestamp_unix_ms", "heart_rate_bpm",
                                       "rr_intervals_ms", "sensor_contact", "source_device"]

    public static func samplesCSV(_ samples: [HeartRateSample]) -> String {
        var lines = [row(samplesHeader)]
        lines.reserveCapacity(samples.count + 1)
        for s in samples {
            lines.append(row([s.sessionID, ISOTimestamp.format(milliseconds: s.timestampMs), String(s.timestampMs),
                              String(s.bpm), s.rrIntervalsMs.map { "\($0)" }.joined(separator: ";"),
                              s.sensorContact.rawValue, s.sourceDevice]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static let sessionsHeader = ["session_id", "kind", "status", "started_at_utc", "ended_at_utc",
                                        "duration_seconds", "sample_count", "device_identifier", "device_name", "notes"]

    public static func sessionsCSV(_ sessions: [RecordingSession]) -> String {
        var lines = [row(sessionsHeader)]
        for s in sessions {
            lines.append(row([s.id, s.kind.rawValue, s.status.rawValue, ISOTimestamp.format(s.startedAt),
                              s.endedAt.map(ISOTimestamp.format) ?? "",
                              s.endedAt.map { String(Int($0.timeIntervalSince(s.startedAt).rounded())) } ?? "",
                              String(s.sampleCount), s.deviceIdentifier ?? "", s.deviceName ?? "", s.notes]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static let restingHeader = ["measurement_id", "session_id", "started_at_utc", "day", "time_zone", "posture",
                                       "valid", "median_bpm", "mean_bpm", "min_bpm", "max_bpm", "sd_bpm", "sample_count",
                                       "coverage", "largest_gap_seconds", "flags", "settle_seconds", "window_seconds",
                                       "notes"]

    public static func restingCSV(_ items: [RestingMeasurement]) -> String {
        var lines = [row(restingHeader)]
        for m in items {
            let r = m.result
            lines.append(row([m.id, m.sessionID, ISOTimestamp.format(m.startedAt), m.day.string, m.timeZoneIdentifier,
                              m.posture.rawValue, r.isValid ? "true" : "false", fixed(r.medianBPM, 1), fixed(r.meanBPM),
                              r.minBPM.map(String.init) ?? "", r.maxBPM.map(String.init) ?? "", fixed(r.sdBPM),
                              String(r.sampleCount), fixed(r.coverage, 3), fixed(r.largestGapSeconds, 1),
                              r.flags.map(\.rawValue).joined(separator: ";"), String(Int(m.settings.settleSeconds)),
                              String(Int(m.settings.windowSeconds)), m.notes]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func annotationsCSV(_ items: [Annotation]) -> String {
        var lines = [row(["annotation_id", "day", "kind", "value", "text", "session_id", "created_at_utc"])]
        for a in items {
            lines.append(row([a.id, a.day.string, a.kind.rawValue, number(a.value), a.text, a.sessionID ?? "",
                              ISOTimestamp.format(a.createdAt)]))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Everything in the database, for the JSON export.
public struct ExportBundle: Codable, Sendable {
    public var schemaVersion = 1
    public var exportedAt: Date
    public var conventions: [String: String] = [
        "timestamps": "ISO 8601, UTC, millisecond precision",
        "day": "Local calendar date (yyyy-MM-dd) where the value was measured",
        "heart_rate": "beats per minute",
        "rr_intervals": "milliseconds (sensor resolution 1/1024 s)",
        "sample_timestamp": "Time the phone received the Bluetooth notification",
        "sources": "controlled = this app's 5-minute measurement; whoopOvernight = imported WHOOP value; appleHealth = Apple Health",
    ]
    public var sessions: [RecordingSession]
    public var samples: [HeartRateSample]
    public var restingMeasurements: [RestingMeasurement]
    public var importedRestingHR: [ImportedRestingHR]
    public var annotations: [Annotation]
    public var connectionEvents: [ConnectionEvent]

    public init(exportedAt: Date, sessions: [RecordingSession], samples: [HeartRateSample],
                restingMeasurements: [RestingMeasurement], importedRestingHR: [ImportedRestingHR],
                annotations: [Annotation], connectionEvents: [ConnectionEvent]) {
        self.exportedAt = exportedAt
        self.sessions = sessions
        self.samples = samples
        self.restingMeasurements = restingMeasurements
        self.importedRestingHR = importedRestingHR
        self.annotations = annotations
        self.connectionEvents = connectionEvents
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISOTimestamp.format(date))
        }
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> ExportBundle {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let ms = ISOTimestamp.parseMilliseconds(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad timestamp \(s)")
            }
            return ISOTimestamp.date(milliseconds: ms)
        }
        return try dec.decode(ExportBundle.self, from: data)
    }
}

/// Minimal RFC 4180 CSV reader (quoted fields, escaped quotes, CRLF/LF).
public enum CSVReader {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = chars.next()
        while let c = pending {
            pending = chars.next()
            if inQuotes {
                if c == "\"" {
                    if pending == "\"" { field.unicodeScalars.append("\""); pending = chars.next() } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true
            case ",": row.append(field); field = ""
            case "\r":
                if pending == "\n" { pending = chars.next() }
                row.append(field); rows.append(row); row = []; field = ""
            case "\n": row.append(field); rows.append(row); row = []; field = ""
            default: field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// Imports WHOOP's overnight resting heart rate from the `physiological_cycles.csv` file in a
/// WHOOP data export (WHOOP app › Profile › App Settings › Data Export).
///
/// Columns are matched by name, case-insensitively: a "resting heart rate" column, and a date
/// column — "Wake onset" if present (the morning the value belongs to), else "Cycle start time".
/// Rows with an empty or non-numeric RHR are skipped.
public enum WhoopCSVImporter {
    public struct Result: Equatable, Sendable {
        public var values: [ImportedRestingHR]
        public var skippedRows: Int
        public var dateColumn: String
    }

    public enum ImportError: Error, Equatable, LocalizedError {
        case missingColumns
        public var errorDescription: String? {
            "This doesn't look like WHOOP's physiological_cycles.csv (no resting heart rate column found)."
        }
    }

    public static func parse(_ text: String, importedAt: Date = Date()) throws -> Result {
        let rows = CSVReader.parse(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else {
            throw ImportError.missingColumns
        }
        guard let rhrIndex = header.firstIndex(where: { $0.contains("resting heart rate") }) else {
            throw ImportError.missingColumns
        }
        let dateIndex = header.firstIndex(where: { $0.hasPrefix("wake onset") })
            ?? header.firstIndex(where: { $0.hasPrefix("cycle start time") })
        guard let dateIndex else { throw ImportError.missingColumns }

        var byDay: [CalendarDay: Double] = [:]
        var skipped = 0
        for r in rows.dropFirst() {
            guard r.count > max(rhrIndex, dateIndex),
                  let bpm = Double(r[rhrIndex].trimmingCharacters(in: .whitespaces)), bpm > 0,
                  let day = CalendarDay(string: r[dateIndex]) else {
                if !(r.count == 1 && r[0].isEmpty) { skipped += 1 }
                continue
            }
            byDay[day] = bpm // one value per day; a later row for the same day wins
        }
        let values = byDay.keys.sorted().map {
            ImportedRestingHR(source: .whoopOvernight, day: $0, bpm: byDay[$0]!, importedAt: importedAt)
        }
        return Result(values: values, skippedRows: skipped, dateColumn: header[dateIndex])
    }
}

/// Deterministic synthetic heart rate stream for UI and persistence testing without hardware.
/// Every sample it produces is labeled with `sourceName` so it is never mistaken for real data.
public struct MockHeartRateGenerator: Sendable {
    public static let sourceName = "Simulated"

    public var baseBPM: Double
    /// Seconds between simulated dropouts (nil = never), each lasting `dropoutLength` seconds.
    public var dropoutEvery: TimeInterval?
    public var dropoutLength: TimeInterval
    private var state: UInt64

    public init(baseBPM: Double = 62, seed: UInt64 = 42, dropoutEvery: TimeInterval? = nil, dropoutLength: TimeInterval = 15) {
        self.baseBPM = baseBPM
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        self.dropoutEvery = dropoutEvery
        self.dropoutLength = dropoutLength
    }

    private mutating func nextUnit() -> Double {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let v = state &* 2685821657736338717
        return Double(v >> 11) / Double(1 << 53)
    }

    /// Measurement at `elapsed` seconds into the stream, or nil during a simulated dropout.
    public mutating func measurement(elapsed: TimeInterval) -> HeartRateMeasurement? {
        if let every = dropoutEvery, every > 0, elapsed.truncatingRemainder(dividingBy: every) > every - dropoutLength {
            return nil
        }
        let slow = 4 * sin(elapsed / 90 * 2 * .pi)
        let breath = 2 * sin(elapsed / 5 * 2 * .pi)
        let noise = (nextUnit() - 0.5) * 2
        let bpm = Int((baseBPM + slow + breath + noise).rounded())
        let rr = 60_000.0 / Double(bpm)
        let ticks = (rr / HeartRateMeasurementParser.msPerRRTick).rounded()
        return HeartRateMeasurement(bpm: bpm, sensorContact: .detected,
                                    rrIntervalsMs: [ticks * HeartRateMeasurementParser.msPerRRTick])
    }
}
