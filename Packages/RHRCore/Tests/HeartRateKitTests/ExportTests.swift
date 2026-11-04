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

    func testFormulaInjectionIsNeutralized() {
        for evil in ["=HYPERLINK(\"http://x\",\"hi\")", "+1+1", "-2+3", "@SUM(A1)", "\tcmd", "\rcmd"] {
            XCTAssertEqual(CSVExporter.text(evil), "'" + evil)
        }
        XCTAssertEqual(CSVExporter.text("WHOOP MG"), "WHOOP MG")
        XCTAssertEqual(CSVExporter.text(""), "")
        XCTAssertEqual(CSVExporter.text("a=b"), "a=b")

        // Device names (set by whoever is broadcasting) and notes are protected in every export.
        let s = RecordingSession(id: "x", startedAt: t0, deviceIdentifier: "id", deviceName: "=cmd|' /C calc'!A0",
                                 notes: "@evil")
        let rows = CSVReader.parse(CSVExporter.sessionsCSV([s]))
        XCTAssertEqual(rows[1][8], "'=cmd|' /C calc'!A0")
        XCTAssertEqual(rows[1][9], "'@evil")
        let sample = HeartRateSample(sessionID: "x", timestamp: t0, bpm: 60, sourceDevice: "-WHOOP")
        XCTAssertEqual(CSVReader.parse(CSVExporter.samplesCSV([sample]))[1][6], "'-WHOOP")
        let a = Annotation(day: CalendarDay(year: 2026, month: 1, day: 1), createdAt: t0, kind: .note, text: "=1+1")
        XCTAssertEqual(CSVReader.parse(CSVExporter.annotationsCSV([a]))[1][4], "'=1+1")
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

    func testWhoopImportRejectsImplausibleValuesAndDates() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let csv = """
        Cycle start time,Resting heart rate (bpm)
        2026-10-01 07:00:00,55
        2026-10-02 07:00:00,inf
        2026-10-03 07:00:00,nan
        2026-10-04 07:00:00,9999
        2026-10-05 07:00:00,10
        0001-01-01 07:00:00,55
        1999-12-31 07:00:00,55
        2099-01-01 07:00:00,55
        2026-10-27 07:00:00,56
        """
        let r = try WhoopCSVImporter.parse(csv, importedAt: now, calendar: cal)
        XCTAssertEqual(r.values.map(\.day.string), ["2026-10-01", "2026-10-27"])
        XCTAssertEqual(r.skippedRows, 7)
        XCTAssertTrue(r.values.allSatisfy { $0.bpm.isFinite && (25...250).contains($0.bpm) })
    }

    func testWhoopImportRejectsHugeFile() {
        let header = "Cycle start time,Resting heart rate (bpm)\n"
        let big = header + String(repeating: "x", count: WhoopCSVImporter.maxFileBytes)
        XCTAssertThrowsError(try WhoopCSVImporter.parse(big)) { error in
            XCTAssertEqual(error as? WhoopCSVImporter.ImportError, .fileTooLarge)
        }
    }

    func testDeviceNameSanitizing() {
        XCTAssertEqual(DeviceName.sanitize("WHOOP 4C1234567"), "WHOOP 4C1234567")
        XCTAssertNil(DeviceName.sanitize(nil))
        XCTAssertNil(DeviceName.sanitize("  \n\t "))
        XCTAssertNil(DeviceName.sanitize("\u{200B}\u{202E}"))
        // Newlines, bidi overrides (which can make text display reversed) and zero-width characters go.
        XCTAssertEqual(DeviceName.sanitize("WHO\u{202E}OP\n\u{200B}MG"), "WHOOPMG")
        XCTAssertEqual(DeviceName.sanitize(String(repeating: "A", count: 500))?.count, DeviceName.maxLength)
        XCTAssertEqual(DeviceName.sanitize("Polar H10 ❤️"), "Polar H10 ❤️")
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
