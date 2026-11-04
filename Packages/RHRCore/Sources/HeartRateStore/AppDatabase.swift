import Foundation
import GRDB
import HeartRateKit

/// SQLite storage (GRDB). All timestamps are stored as integer milliseconds since the Unix
/// epoch (UTC); calendar days as `yyyy-MM-dd` text.
///
/// Thread-safe: GRDB serializes writes. Small writes (a batch of samples) are done synchronously;
/// large reads (history, export) should use the async variants.
public final class AppDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the on-disk database at `url`.
    ///
    /// On iOS the containing directory is given `completeUntilFirstUserAuthentication`
    /// protection: data is encrypted at rest while the phone is locked after a reboot, but can
    /// still be written by background Bluetooth collection while the phone is locked.
    public static func openOnDisk(at url: URL) throws -> AppDatabase {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: dir.path)
        #endif
        var config = Self.baseConfiguration()
        config.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: config)
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                              ofItemAtPath: url.path)
        #endif
        return try AppDatabase(pool)
    }

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: baseConfiguration()))
    }

    static func baseConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // Overwrite deleted rows with zeros instead of leaving them readable in free pages,
            // so deleted health data can't be recovered from the database file.
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return config
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE recording_session (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at_ms INTEGER NOT NULL,
                    ended_at_ms INTEGER,
                    device_identifier TEXT,
                    device_name TEXT,
                    sample_count INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    notes TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX recording_session_started ON recording_session(started_at_ms);

                CREATE TABLE heart_rate_sample (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL REFERENCES recording_session(id) ON DELETE CASCADE,
                    timestamp_ms INTEGER NOT NULL,
                    heart_rate_bpm INTEGER NOT NULL,
                    rr_intervals_ms TEXT NOT NULL DEFAULT '',
                    sensor_contact TEXT NOT NULL,
                    source_device TEXT NOT NULL,
                    UNIQUE(session_id, timestamp_ms)
                );
                CREATE INDEX heart_rate_sample_time ON heart_rate_sample(timestamp_ms);

                CREATE TABLE resting_measurement (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES recording_session(id) ON DELETE CASCADE,
                    started_at_ms INTEGER NOT NULL,
                    day TEXT NOT NULL,
                    time_zone TEXT NOT NULL,
                    posture TEXT NOT NULL,
                    settings_json TEXT NOT NULL,
                    median_bpm REAL,
                    mean_bpm REAL,
                    min_bpm INTEGER,
                    max_bpm INTEGER,
                    sd_bpm REAL,
                    sample_count INTEGER NOT NULL,
                    coverage REAL NOT NULL,
                    largest_gap_seconds REAL NOT NULL,
                    flags TEXT NOT NULL,
                    is_valid INTEGER NOT NULL,
                    notes TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX resting_measurement_day ON resting_measurement(day);

                CREATE TABLE imported_rhr (
                    source TEXT NOT NULL,
                    day TEXT NOT NULL,
                    bpm REAL NOT NULL,
                    imported_at_ms INTEGER NOT NULL,
                    notes TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (source, day)
                );

                CREATE TABLE annotation (
                    id TEXT PRIMARY KEY NOT NULL,
                    day TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    session_id TEXT REFERENCES recording_session(id) ON DELETE SET NULL,
                    kind TEXT NOT NULL,
                    value REAL,
                    text TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX annotation_day ON annotation(day);

                CREATE TABLE connection_event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT REFERENCES recording_session(id) ON DELETE CASCADE,
                    timestamp_ms INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    detail TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX connection_event_time ON connection_event(timestamp_ms);
                """)
        }
        return m
    }
}

// MARK: - Row mapping

extension HeartRateSample {
    init(row: Row) {
        let rr: String = row["rr_intervals_ms"]
        self.init(id: row["id"], sessionID: row["session_id"],
                  timestamp: ISOTimestamp.date(milliseconds: row["timestamp_ms"]),
                  bpm: row["heart_rate_bpm"],
                  rrIntervalsMs: rr.isEmpty ? [] : rr.split(separator: ";").compactMap { Double($0) },
                  sensorContact: SensorContact(rawValue: row["sensor_contact"]) ?? .notSupported,
                  sourceDevice: row["source_device"])
    }

    var rrText: String { rrIntervalsMs.map { "\($0)" }.joined(separator: ";") }
}

extension RecordingSession {
    init(row: Row) {
        let ended: Int64? = row["ended_at_ms"]
        self.init(id: row["id"], startedAt: ISOTimestamp.date(milliseconds: row["started_at_ms"]),
                  endedAt: ended.map(ISOTimestamp.date(milliseconds:)), deviceIdentifier: row["device_identifier"],
                  deviceName: row["device_name"], sampleCount: row["sample_count"],
                  status: SessionStatus(rawValue: row["status"]) ?? .interrupted,
                  kind: SessionKind(rawValue: row["kind"]) ?? .freeform, notes: row["notes"])
    }
}

extension RestingMeasurement {
    init(row: Row) {
        let settingsJSON: String = row["settings_json"]
        let settings = (try? JSONDecoder().decode(RestingHRProtocol.self, from: Data(settingsJSON.utf8))) ?? .standard
        let flagsText: String = row["flags"]
        let result = RestingHRResult(
            medianBPM: row["median_bpm"], meanBPM: row["mean_bpm"], minBPM: row["min_bpm"], maxBPM: row["max_bpm"],
            sdBPM: row["sd_bpm"], sampleCount: row["sample_count"], coverage: row["coverage"],
            largestGapSeconds: row["largest_gap_seconds"],
            flags: flagsText.split(separator: ";").compactMap { RestingFlag(rawValue: String($0)) })
        let dayText: String = row["day"]
        self.init(id: row["id"], sessionID: row["session_id"],
                  startedAt: ISOTimestamp.date(milliseconds: row["started_at_ms"]),
                  day: CalendarDay(string: dayText) ?? CalendarDay(year: 1970, month: 1, day: 1),
                  timeZoneIdentifier: row["time_zone"], posture: Posture(rawValue: row["posture"]) ?? .sitting,
                  settings: settings, result: result, notes: row["notes"])
    }
}

extension ImportedRestingHR {
    init(row: Row) {
        let dayText: String = row["day"]
        self.init(source: RHRSource(rawValue: row["source"]) ?? .whoopOvernight,
                  day: CalendarDay(string: dayText) ?? CalendarDay(year: 1970, month: 1, day: 1), bpm: row["bpm"],
                  importedAt: ISOTimestamp.date(milliseconds: row["imported_at_ms"]), notes: row["notes"])
    }
}

extension Annotation {
    init(row: Row) {
        let dayText: String = row["day"]
        self.init(id: row["id"], day: CalendarDay(string: dayText) ?? CalendarDay(year: 1970, month: 1, day: 1),
                  createdAt: ISOTimestamp.date(milliseconds: row["created_at_ms"]), sessionID: row["session_id"],
                  kind: AnnotationKind(rawValue: row["kind"]) ?? .note, value: row["value"], text: row["text"])
    }
}

extension ConnectionEvent {
    init(row: Row) {
        self.init(id: row["id"], sessionID: row["session_id"],
                  timestamp: ISOTimestamp.date(milliseconds: row["timestamp_ms"]), kind: row["kind"],
                  detail: row["detail"])
    }
}
