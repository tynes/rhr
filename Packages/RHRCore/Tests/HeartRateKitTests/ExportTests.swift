import XCTest
@testable import HeartRateKit

final class ExportTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000.25)

    func testCSVEscaping() {
        XCTAssertEqual(CSVExporter.escape("plain"), "plain")
        XCTAssertEqual(CSVExporter.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVExporter.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSVExporter.escape("line\nbreak"), "\"line\nbreak\"")
    }

    func testSamplesCSVRoundTrip() {
        let samples = [
            HeartRateSample(sessionID: "s1", timestamp: t0, bpm: 61, rrIntervalsMs: [976.5625, 1000], sensorContact: .detected, sourceDevice: "WHOOP, MG"),
            HeartRateSample(sessionID: "s1", timestamp: t0.addingTimeInterval(1.001), bpm: 62, sourceDevice: "WHOOP MG"),
        ]
        let csv = CSVExporter.samplesCSV(samples)
        let rows = CSVReader.parse(csv)
        XCTAssertEqual(rows[0], CSVExporter.samplesHeader)
        XCTAssertEqual(rows.count, 3)
        // Reconstruct and compare with the originals.
        let rebuilt = rows.dropFirst().map { r in
            HeartRateSample(sessionID: r[0], timestamp: ISOTimestamp.date(milliseconds: ISOTimestamp.parseMilliseconds(r[1])!),
                            bpm: Int(r[3])!, rrIntervalsMs: r[4].isEmpty ? [] : r[4].split(separator: ";").map { Double($0)! },
                            sensorContact: SensorContact(rawValue: r[5])!, sourceDevice: r[6])
        }
        XCTAssertEqual(Array(rebuilt), samples)
        XCTAssertEqual(rows[1][1], "2027-01-15T08:00:00.250Z")
        XCTAssertEqual(rows[1][2], "1800000000250")
    }

    func testSessionsAndRestingCSV() {
        let s = RecordingSession(id: "x", startedAt: t0, endedAt: t0.addingTimeInterval(1800), sampleCount: 1800, status: .completed, notes: "after \"coffee\"")
        let rows = CSVReader.parse(CSVExporter.sessionsCSV([s]))
        XCTAssertEqual(rows[1][5], "1800")
        XCTAssertEqual(rows[1][9], "after \"coffee\"")

        let result = RestingHRResult(medianBPM: 55.5, meanBPM: 55.6, minBPM: 52, maxBPM: 60, sdBPM: 1.2, sampleCount: 170,
                                     coverage: 0.97, largestGapSeconds: 3, flags: [.largeGap])
        let m = RestingMeasurement(sessionID: "x", startedAt: t0, day: CalendarDay(year: 2027, month: 1, day: 15),
                                   timeZoneIdentifier: "America/Chicago", posture: .lyingDown, settings: .standard, result: result)
        let r = CSVReader.parse(CSVExporter.restingCSV([m]))
        XCTAssertEqual(r[0], CSVExporter.restingHeader)
        XCTAssertEqual(r[1][5], "lyingDown")
        XCTAssertEqual(r[1][6], "true")
        XCTAssertEqual(r[1][7], "55.5")
        XCTAssertEqual(r[1][15], "largeGap")
    }

    func testJSONRoundTrip() throws {
        let sample = HeartRateSample(id: 1, sessionID: "s", timestamp: t0, bpm: 60, rrIntervalsMs: [1000], sensorContact: .detected, sourceDevice: "W")
        let bundle = ExportBundle(exportedAt: t0, sessions: [RecordingSession(id: "s", startedAt: t0)], samples: [sample],
                                  restingMeasurements: [], importedRestingHR: [ImportedRestingHR(source: .whoopOvernight, day: CalendarDay(year: 2026, month: 1, day: 2), bpm: 51, importedAt: t0)],
                                  annotations: [Annotation(day: CalendarDay(year: 2026, month: 1, day: 2), createdAt: t0, kind: .alcohol, value: 2)],
                                  connectionEvents: [])
        let data = try bundle.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"2027-01-15T08:00:00.250Z\""))
        XCTAssertTrue(text.contains("\"2026-01-02\""))
        let back = try ExportBundle.decode(data)
        XCTAssertEqual(back.samples, [sample])
        XCTAssertEqual(back.annotations, bundle.annotations)
        XCTAssertEqual(back.importedRestingHR, bundle.importedRestingHR)
    }

    func testCSVReaderEdgeCases() {
        XCTAssertEqual(CSVReader.parse("a,b\r\n1,\"x,\"\"y\"\"\"\n"), [["a", "b"], ["1", "x,\"y\""]])
        XCTAssertEqual(CSVReader.parse("a,,c"), [["a", "", "c"]])
    }

    func testWhoopImport() throws {
        let csv = """
        \u{FEFF}Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Sleep onset,Wake onset
        2026-10-29 23:10:00,2026-10-30 23:05:00,UTC-05:00,66,52,70,2026-10-29 23:10:00,2026-10-30 07:01:00
        2026-10-30 23:05:00,,UTC-05:00,,,,2026-10-30 23:05:00,
        2026-10-28 22:50:00,2026-10-29 23:10:00,UTC-05:00,40,57,55,2026-10-28 22:50:00,2026-10-29 06:40:00
        """
        let r = try WhoopCSVImporter.parse(csv)
        XCTAssertEqual(r.dateColumn, "wake onset")
        XCTAssertEqual(r.values.map(\.day.string), ["2026-10-29", "2026-10-30"])
        XCTAssertEqual(r.values.map(\.bpm), [57, 52])
        XCTAssertEqual(r.skippedRows, 1)
        XCTAssertTrue(r.values.allSatisfy { $0.source == .whoopOvernight })
    }

    func testWhoopImportFallsBackToCycleStart() throws {
        let r = try WhoopCSVImporter.parse("Cycle start time,Resting heart rate (bpm)\n2026-10-01 07:00:00,55\n")
        XCTAssertEqual(r.values.first?.day.string, "2026-10-01")
        XCTAssertThrowsError(try WhoopCSVImporter.parse("date,value\n2026-10-01,55\n"))
    }

    func testMockGeneratorIsDeterministicAndPlausible() {
        var a = MockHeartRateGenerator(seed: 7), b = MockHeartRateGenerator(seed: 7)
        for t in 0..<200 {
            let ma = a.measurement(elapsed: Double(t)), mb = b.measurement(elapsed: Double(t))
            XCTAssertEqual(ma, mb)
            XCTAssertTrue(ma!.isPlausible)
        }
        var g = MockHeartRateGenerator(dropoutEvery: 60, dropoutLength: 10)
        XCTAssertNil(g.measurement(elapsed: 55))
        XCTAssertNotNil(g.measurement(elapsed: 45))
    }
}
