import XCTest
@testable import HeartRateKit

final class ParserTests: XCTestCase {
    func testEightBitHeartRate() throws {
        let m = try HeartRateMeasurementParser.parse([0x00, 64])
        XCTAssertEqual(m.bpm, 64)
        XCTAssertEqual(m.sensorContact, .notSupported)
        XCTAssertNil(m.energyExpendedKJ)
        XCTAssertEqual(m.rrIntervalsMs, [])
        XCTAssertTrue(m.isPlausible)
    }

    func testSixteenBitHeartRateLittleEndian() throws {
        // 0x012C = 300 → implausible but decoded correctly.
        let m = try HeartRateMeasurementParser.parse([0x01, 0x2C, 0x01])
        XCTAssertEqual(m.bpm, 300)
        XCTAssertFalse(m.isPlausible)
        let m2 = try HeartRateMeasurementParser.parse([0x01, 72, 0x00])
        XCTAssertEqual(m2.bpm, 72)
    }

    func testSensorContactBits() throws {
        XCTAssertEqual(try HeartRateMeasurementParser.parse([0x06, 60]).sensorContact, .detected)
        XCTAssertEqual(try HeartRateMeasurementParser.parse([0x04, 60]).sensorContact, .notDetected)
        XCTAssertEqual(try HeartRateMeasurementParser.parse([0x02, 60]).sensorContact, .notSupported)
    }

    func testRRIntervalsConvertedToMilliseconds() throws {
        // flags: RR present (0x10); HR 60; RR 1024 (=1000 ms) and 512 (=500 ms)
        let m = try HeartRateMeasurementParser.parse([0x10, 60, 0x00, 0x04, 0x00, 0x02])
        XCTAssertEqual(m.rrIntervalsMs, [1000, 500])
        XCTAssertFalse(m.droppedTrailingByte)
        // 820 ticks = 800.78125 ms exactly
        let m2 = try HeartRateMeasurementParser.parse([0x10, 75, 0x34, 0x03])
        XCTAssertEqual(m2.rrIntervalsMs, [800.78125])
    }

    func testEnergyExpendedThenRR() throws {
        // flags: 16-bit HR, energy, RR, contact detected → 0x01|0x08|0x10|0x06 = 0x1F
        let m = try HeartRateMeasurementParser.parse([0x1F, 70, 0x00, 0x10, 0x00, 0x00, 0x04])
        XCTAssertEqual(m.bpm, 70)
        XCTAssertEqual(m.energyExpendedKJ, 16)
        XCTAssertEqual(m.rrIntervalsMs, [1000])
        XCTAssertEqual(m.sensorContact, .detected)
    }

    func testRRFlagWithoutIntervalsIsAllowed() throws {
        let m = try HeartRateMeasurementParser.parse([0x10, 61])
        XCTAssertEqual(m.bpm, 61)
        XCTAssertEqual(m.rrIntervalsMs, [])
    }

    func testTrailingOddRRByteDropped() throws {
        let m = try HeartRateMeasurementParser.parse([0x10, 61, 0x00, 0x04, 0x07])
        XCTAssertEqual(m.rrIntervalsMs, [1000])
        XCTAssertTrue(m.droppedTrailingByte)
    }

    func testMalformedPackets() {
        XCTAssertThrowsError(try HeartRateMeasurementParser.parse([])) { XCTAssertEqual($0 as? HeartRateParseError, .empty) }
        XCTAssertThrowsError(try HeartRateMeasurementParser.parse([0x00])) { XCTAssertEqual($0 as? HeartRateParseError, .truncatedHeartRate) }
        XCTAssertThrowsError(try HeartRateMeasurementParser.parse([0x01, 60])) { XCTAssertEqual($0 as? HeartRateParseError, .truncatedHeartRate) }
        XCTAssertThrowsError(try HeartRateMeasurementParser.parse([0x08, 60, 0x01])) { XCTAssertEqual($0 as? HeartRateParseError, .truncatedEnergyExpended) }
    }

    func testDataOverloadAndZeroBPM() throws {
        let m = try HeartRateMeasurementParser.parse(Data([0x00, 0x00]))
        XCTAssertEqual(m.bpm, 0)
        XCTAssertFalse(m.isPlausible, "0 BPM (off-wrist) must never count as a reading")
    }
}
