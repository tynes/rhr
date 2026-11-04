import XCTest
import GRDB
@testable import HeartRateKit
@testable import HeartRateStore

final class StoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000.5)
    var db: AppDatabase!

    override func setUpWithError() throws {
        db = try AppDatabase.inMemory()
    }

    func sample(_ i: Int, session: String = "s1", bpm: Int = 60) -> HeartRateSample {
        HeartRateSample(sessionID: session, timestamp: t0.addingTimeInterval(Double(i)), bpm: bpm,
                        rrIntervalsMs: i % 2 == 0 ? [976.5625] : [], sensorContact: .detected, sourceDevice: "WHOOP MG")
    }

    func testMigrationCreatesTables() throws {
        let tables = try db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for t in ["annotation", "connection_event", "heart_rate_sample", "imported_rhr", "recording_session", "resting_measurement"] {
            XCTAssertTrue(tables.contains(t), t)
        }
        // Migrating an already-migrated database is a no-op.
        XCTAssertNoThrow(try AppDatabase.migrator.migrate(db.writer))
    }

    func testOnDiskReopenPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("rhr.sqlite")
        do {
            let d = try AppDatabase.openOnDisk(at: url)
            try d.insertSession(RecordingSession(id: "s1", startedAt: t0))
            try d.persist((0..<10).map { sample($0) }, sessionID: "s1")
        }
        let reopened = try AppDatabase.openOnDisk(at: url)
        XCTAssertEqual(try reopened.fetchSamples(sessionID: "s1").count, 10)
        XCTAssertEqual(try reopened.fetchSession(id: "s1")?.sampleCount, 10)
        try? FileManager.default.removeItem(at: dir)
    }

    func testPersistIsIdempotent() throws {
        try db.insertSession(RecordingSession(id: "s1", startedAt: t0))
        let batch = (0..<5).map { sample($0) }
        try db.persist(batch, sessionID: "s1")
        try db.persist(batch, sessionID: "s1") // retried batch, e.g. after a reconnect
        try db.persist([sample(5)], sessionID: "s1")
        let stored = try db.fetchSamples(sessionID: "s1")
        XCTAssertEqual(stored.count, 6)
        XCTAssertEqual(try db.fetchSession(id: "s1")?.sampleCount, 6, "count tracks inserted rows, not attempts")
        XCTAssertEqual(stored.map { $0.id == nil }, Array(repeating: false, count: 6))
        var expected = batch + [sample(5)]
        for i in expected.indices { expected[i].id = stored[i].id }
        XCTAssertEqual(stored, expected, "values survive the round trip exactly")
    }

    func testEngineWithDatabaseSink() throws {
        try db.insertSession(RecordingSession(id: "s1", startedAt: t0))
        let engine = RecordingEngine(sink: db, configuration: .init(maxBatchSize: 10, maxFlushInterval: 2))
        engine.start(sessionID: "s1", at: t0)
        for i in 0..<1800 { // 30 minutes at 1 Hz
            engine.ingest(HeartRateMeasurement(bpm: 55 + i % 10, sensorContact: .detected), at: t0.addingTimeInterval(Double(i)), sourceDevice: "WHOOP MG")
        }
        XCTAssertTrue(engine.stop(at: t0.addingTimeInterval(1800)))
        try db.finishSession(id: "s1", endedAt: t0.addingTimeInterval(1800), status: .completed)
        let s = try XCTUnwrap(db.fetchSession(id: "s1"))
        XCTAssertEqual(s.sampleCount, 1800)
        XCTAssertEqual(s.status, .completed)
        XCTAssertEqual(try db.fetchSamples(sessionID: "s1").count, 1800)
        XCTAssertEqual(try db.lastSampleTime(sessionID: "s1"), ISOTimestamp.truncated(t0.addingTimeInterval(1799)))
    }

    func testOpenSessionsAndDelete() throws {
        try db.insertSession(RecordingSession(id: "a", startedAt: t0))
        try db.insertSession(RecordingSession(id: "b", startedAt: t0.addingTimeInterval(10), status: .completed))
        try db.persist([sample(0, session: "a")], sessionID: "a")
        try db.insertEvent(ConnectionEvent(sessionID: "a", timestamp: t0, kind: "disconnected"))
        XCTAssertEqual(try db.fetchOpenSessions().map(\.id), ["a"])
        XCTAssertEqual(try db.fetchSessions().map(\.id), ["b", "a"])
        try db.deleteSession(id: "a")
        XCTAssertEqual(try db.fetchSamples(sessionID: "a").count, 0, "samples cascade")
        XCTAssertEqual(try db.fetchEvents(sessionID: "a").count, 0, "events cascade")
    }

    func testRestingMeasurementRoundTrip() throws {
        try db.insertSession(RecordingSession(id: "r", startedAt: t0, kind: .resting))
        var settings = RestingHRProtocol.standard
        settings.minimumCoverage = 0.75
        let result = RestingHRResult(medianBPM: 54, meanBPM: 54.2, minBPM: 51, maxBPM: 58, sdBPM: 1.4, sampleCount: 178,
                                     coverage: 0.99, largestGapSeconds: 2, flags: [.largeGap, .contactLost])
        let m = RestingMeasurement(sessionID: "r", startedAt: t0, day: CalendarDay(year: 2027, month: 1, day: 15),
                                   timeZoneIdentifier: "Europe/Berlin", posture: .lyingDown, settings: settings, result: result,
                                   notes: "after coffee")
        try db.saveRestingMeasurement(m)
        XCTAssertEqual(try db.fetchRestingMeasurements(), [m])
        try db.updateRestingNotes(id: m.id, notes: "edited")
        XCTAssertEqual(try db.fetchRestingMeasurement(sessionID: "r")?.notes, "edited")
    }

    func testImportedUpsertAndAnnotations() throws {
        let d = CalendarDay(year: 2026, month: 10, day: 1)
        try db.upsertImported([ImportedRestingHR(source: .whoopOvernight, day: d, bpm: 50, importedAt: t0)])
        try db.upsertImported([ImportedRestingHR(source: .whoopOvernight, day: d, bpm: 51, importedAt: t0)])
        XCTAssertEqual(try db.fetchImported().map(\.bpm), [51])

        let a = Annotation(day: d, createdAt: t0, kind: .exercise, value: 4, text: "Intervals")
        try db.saveAnnotation(a)
        XCTAssertEqual(try db.fetchAnnotations(), [a])
        try db.deleteAnnotation(id: a.id)
        XCTAssertEqual(try db.fetchAnnotations(), [])
    }

    func testExportReproducesStoredMeasurements() async throws {
        try db.insertSession(RecordingSession(id: "s1", startedAt: t0))
        try db.persist((0..<100).map { sample($0, bpm: 50 + $0 % 30) }, sessionID: "s1")
        let bundle = try await db.exportBundle(now: t0)
        XCTAssertEqual(bundle.samples.count, 100)
        let csv = CSVExporter.samplesCSV(bundle.samples)
        let rows = CSVReader.parse(csv).dropFirst()
        let stored = try db.fetchSamples(sessionID: "s1")
        XCTAssertEqual(rows.count, stored.count)
        for (row, s) in zip(rows, stored) {
            XCTAssertEqual(Int64(row[2]), s.timestampMs)
            XCTAssertEqual(Int(row[3]), s.bpm)
            XCTAssertEqual(row[4], s.rrIntervalsMs.map { "\($0)" }.joined(separator: ";"))
        }
        let decoded = try ExportBundle.decode(try bundle.jsonData())
        XCTAssertEqual(decoded.samples, stored)
    }

    func testDeleteAllData() throws {
        try db.insertSession(RecordingSession(id: "s1", startedAt: t0))
        try db.persist([sample(0)], sessionID: "s1")
        try db.saveAnnotation(Annotation(day: CalendarDay(year: 2026, month: 1, day: 1), kind: .note, text: "x"))
        try db.deleteAllData()
        XCTAssertEqual(try db.counts(), AppDatabase.Counts(sessions: 0, samples: 0, restingMeasurements: 0, annotations: 0, imported: 0))
    }

    func testSecureDeleteIsOn() throws {
        XCTAssertTrue(try db.secureDeleteEnabled())
    }

    /// After "Delete all data", deleted text must not be recoverable from the database file or its WAL.
    func testDeleteAllLeavesNoTraceOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rhr.sqlite")
        let marker = "SECRET-NOTE-\(UUID().uuidString)"
        do {
            let disk = try AppDatabase.openOnDisk(at: url)
            XCTAssertTrue(try disk.secureDeleteEnabled())
            try disk.insertSession(RecordingSession(id: "s1", startedAt: t0, notes: marker))
            try disk.persist((0..<50).map { sample($0) }, sessionID: "s1")
            try disk.saveAnnotation(Annotation(day: CalendarDay(year: 2026, month: 1, day: 1), kind: .note, text: marker))
            try disk.deleteAllData()
            XCTAssertEqual(try disk.counts().sessions, 0)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for file in files {
                let bytes = try Data(contentsOf: file)
                XCTAssertNil(bytes.range(of: Data(marker.utf8)), "deleted text still present in \(file.lastPathComponent)")
            }
        }
    }
}
