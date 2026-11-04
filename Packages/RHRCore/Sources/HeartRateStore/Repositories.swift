import Foundation
import GRDB
import HeartRateKit

// MARK: - Samples (SampleSink)

extension AppDatabase: SampleSink {
    /// Inserts a batch atomically. Duplicate (session, timestamp) rows are ignored, so retrying a
    /// batch after a partial failure or a reconnect never creates duplicates.
    public func persist(_ samples: [HeartRateSample], sessionID: String) throws {
        guard !samples.isEmpty else { return }
        try writer.write { db in
            var inserted = 0
            let stmt = try db.cachedStatement(sql: """
                INSERT OR IGNORE INTO heart_rate_sample
                    (session_id, timestamp_ms, heart_rate_bpm, rr_intervals_ms, sensor_contact, source_device)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            for s in samples {
                try stmt.execute(arguments: [sessionID, s.timestampMs, s.bpm, s.rrText, s.sensorContact.rawValue, s.sourceDevice])
                inserted += db.changesCount
            }
            try db.execute(sql: "UPDATE recording_session SET sample_count = sample_count + ? WHERE id = ?",
                           arguments: [inserted, sessionID])
        }
    }

    public func fetchSamples(sessionID: String) throws -> [HeartRateSample] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM heart_rate_sample WHERE session_id = ? ORDER BY timestamp_ms",
                             arguments: [sessionID]).map(HeartRateSample.init(row:))
        }
    }

    public func fetchSamplesAsync(sessionID: String) async throws -> [HeartRateSample] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM heart_rate_sample WHERE session_id = ? ORDER BY timestamp_ms",
                             arguments: [sessionID]).map(HeartRateSample.init(row:))
        }
    }

    public func fetchAllSamples() async throws -> [HeartRateSample] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM heart_rate_sample ORDER BY timestamp_ms, id").map(HeartRateSample.init(row:))
        }
    }

    public func lastSampleTime(sessionID: String) throws -> Date? {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(timestamp_ms) FROM heart_rate_sample WHERE session_id = ?",
                               arguments: [sessionID]).map(ISOTimestamp.date(milliseconds:))
        }
    }
}

// MARK: - Sessions

extension AppDatabase {
    public func insertSession(_ s: RecordingSession) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO recording_session (id, started_at_ms, ended_at_ms, device_identifier, device_name,
                    sample_count, status, kind, notes) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [s.id, ISOTimestamp.milliseconds(s.startedAt), s.endedAt.map(ISOTimestamp.milliseconds),
                                 s.deviceIdentifier, s.deviceName, s.sampleCount, s.status.rawValue, s.kind.rawValue, s.notes])
        }
    }

    public func finishSession(id: String, endedAt: Date, status: SessionStatus) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE recording_session SET ended_at_ms = ?, status = ? WHERE id = ?",
                           arguments: [ISOTimestamp.milliseconds(endedAt), status.rawValue, id])
        }
    }

    public func updateSessionNotes(id: String, notes: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE recording_session SET notes = ? WHERE id = ?", arguments: [notes, id])
        }
    }

    public func updateSessionDevice(id: String, identifier: String?, name: String?) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE recording_session SET device_identifier = COALESCE(device_identifier, ?),
                    device_name = COALESCE(device_name, ?) WHERE id = ?
                """, arguments: [identifier, name, id])
        }
    }

    public func fetchSession(id: String) throws -> RecordingSession? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM recording_session WHERE id = ?", arguments: [id]).map(RecordingSession.init(row:))
        }
    }

    public func fetchSessions() throws -> [RecordingSession] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recording_session ORDER BY started_at_ms DESC").map(RecordingSession.init(row:))
        }
    }

    /// Sessions still marked as recording (e.g. the app was terminated mid-recording).
    public func fetchOpenSessions() throws -> [RecordingSession] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM recording_session WHERE status = ? ORDER BY started_at_ms",
                             arguments: [SessionStatus.recording.rawValue]).map(RecordingSession.init(row:))
        }
    }

    public func deleteSession(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM recording_session WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - Resting measurements

extension AppDatabase {
    public func saveRestingMeasurement(_ m: RestingMeasurement) throws {
        let settings = String(decoding: try JSONEncoder().encode(m.settings), as: UTF8.self)
        let r = m.result
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO resting_measurement (id, session_id, started_at_ms, day, time_zone, posture,
                    settings_json, median_bpm, mean_bpm, min_bpm, max_bpm, sd_bpm, sample_count, coverage,
                    largest_gap_seconds, flags, is_valid, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [m.id, m.sessionID, ISOTimestamp.milliseconds(m.startedAt), m.day.string,
                                 m.timeZoneIdentifier, m.posture.rawValue, settings, r.medianBPM, r.meanBPM, r.minBPM,
                                 r.maxBPM, r.sdBPM, r.sampleCount, r.coverage, r.largestGapSeconds,
                                 r.flags.map(\.rawValue).joined(separator: ";"), r.isValid, m.notes])
        }
    }

    public func updateRestingNotes(id: String, notes: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE resting_measurement SET notes = ? WHERE id = ?", arguments: [notes, id])
        }
    }

    public func fetchRestingMeasurements() throws -> [RestingMeasurement] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM resting_measurement ORDER BY started_at_ms DESC").map(RestingMeasurement.init(row:))
        }
    }

    public func fetchRestingMeasurement(sessionID: String) throws -> RestingMeasurement? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM resting_measurement WHERE session_id = ?", arguments: [sessionID])
                .map(RestingMeasurement.init(row:))
        }
    }

    public func deleteRestingMeasurement(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM resting_measurement WHERE id = ?", arguments: [id])
        }
    }
}

// MARK: - Imported resting HR

extension AppDatabase {
    /// Upserts imported values (one per source per day). Returns the number of rows written.
    @discardableResult
    public func upsertImported(_ values: [ImportedRestingHR]) throws -> Int {
        try writer.write { db in
            for v in values {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO imported_rhr (source, day, bpm, imported_at_ms, notes) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [v.source.rawValue, v.day.string, v.bpm, ISOTimestamp.milliseconds(v.importedAt), v.notes])
            }
            return values.count
        }
    }

    public func fetchImported() throws -> [ImportedRestingHR] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM imported_rhr ORDER BY day").map(ImportedRestingHR.init(row:))
        }
    }

    public func deleteImported(source: RHRSource) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM imported_rhr WHERE source = ?", arguments: [source.rawValue])
        }
    }
}

// MARK: - Annotations

extension AppDatabase {
    public func saveAnnotation(_ a: Annotation) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO annotation (id, day, created_at_ms, session_id, kind, value, text)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [a.id, a.day.string, ISOTimestamp.milliseconds(a.createdAt), a.sessionID, a.kind.rawValue,
                                 a.value, a.text])
        }
    }

    public func deleteAnnotation(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM annotation WHERE id = ?", arguments: [id])
        }
    }

    public func fetchAnnotations() throws -> [Annotation] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM annotation ORDER BY day, created_at_ms").map(Annotation.init(row:))
        }
    }
}

// MARK: - Connection events

extension AppDatabase {
    public func insertEvent(_ e: ConnectionEvent) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO connection_event (session_id, timestamp_ms, kind, detail) VALUES (?, ?, ?, ?)",
                           arguments: [e.sessionID, ISOTimestamp.milliseconds(e.timestamp), e.kind, e.detail])
        }
    }

    public func fetchEvents(sessionID: String) throws -> [ConnectionEvent] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM connection_event WHERE session_id = ? ORDER BY timestamp_ms, id",
                             arguments: [sessionID]).map(ConnectionEvent.init(row:))
        }
    }
}

// MARK: - Bulk

extension AppDatabase {
    public func exportBundle(now: Date = Date()) async throws -> ExportBundle {
        try await writer.read { db in
            ExportBundle(
                exportedAt: now,
                sessions: try Row.fetchAll(db, sql: "SELECT * FROM recording_session ORDER BY started_at_ms").map(RecordingSession.init(row:)),
                samples: try Row.fetchAll(db, sql: "SELECT * FROM heart_rate_sample ORDER BY timestamp_ms, id").map(HeartRateSample.init(row:)),
                restingMeasurements: try Row.fetchAll(db, sql: "SELECT * FROM resting_measurement ORDER BY started_at_ms").map(RestingMeasurement.init(row:)),
                importedRestingHR: try Row.fetchAll(db, sql: "SELECT * FROM imported_rhr ORDER BY source, day").map(ImportedRestingHR.init(row:)),
                annotations: try Row.fetchAll(db, sql: "SELECT * FROM annotation ORDER BY day, created_at_ms").map(Annotation.init(row:)),
                connectionEvents: try Row.fetchAll(db, sql: "SELECT * FROM connection_event ORDER BY timestamp_ms, id").map(ConnectionEvent.init(row:))
            )
        }
    }

    /// Deletes every row in every table, then rebuilds the file and empties the write-ahead log
    /// so no copy of the deleted rows is left on disk.
    public func deleteAllData() throws {
        try writer.write { db in
            for table in ["connection_event", "annotation", "imported_rhr", "resting_measurement", "heart_rate_sample", "recording_session"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        try writer.vacuum()
        if writer is DatabasePool {
            try writer.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        }
    }

    /// Whether SQLite secure delete is on for this connection (for tests).
    public func secureDeleteEnabled() throws -> Bool {
        try writer.read { db in try Int.fetchOne(db, sql: "PRAGMA secure_delete") == 1 }
    }

    public struct Counts: Equatable, Sendable {
        public var sessions: Int
        public var samples: Int
        public var restingMeasurements: Int
        public var annotations: Int
        public var imported: Int
    }

    public func counts() throws -> Counts {
        try writer.read { db in
            Counts(sessions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_session") ?? 0,
                   samples: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM heart_rate_sample") ?? 0,
                   restingMeasurements: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM resting_measurement") ?? 0,
                   annotations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotation") ?? 0,
                   imported: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM imported_rhr") ?? 0)
        }
    }
}
