import XCTest
@testable import HeartRateKit

final class CalendarTests: XCTestCase {
    func testJulianRoundTrip() {
        for j in stride(from: -800_000, through: 800_000, by: 997) {
            XCTAssertEqual(CalendarDay(julianDay: j).julianDay, j)
        }
        XCTAssertEqual(CalendarDay(year: 1970, month: 1, day: 1).julianDay, 0)
        XCTAssertEqual(CalendarDay(year: 2024, month: 3, day: 1).adding(days: -1), CalendarDay(year: 2024, month: 2, day: 29))
        XCTAssertEqual(CalendarDay(year: 2025, month: 12, day: 31).adding(days: 1), CalendarDay(year: 2026, month: 1, day: 1))
    }

    func testParsing() {
        XCTAssertEqual(CalendarDay(string: "2026-10-31"), CalendarDay(year: 2026, month: 10, day: 31))
        XCTAssertEqual(CalendarDay(string: "2026-01-02 07:30:00"), CalendarDay(year: 2026, month: 1, day: 2))
        XCTAssertNil(CalendarDay(string: "2026-02-31"))
        XCTAssertNil(CalendarDay(string: "garbage"))
        XCTAssertEqual(CalendarDay(year: 2026, month: 3, day: 5).string, "2026-03-05")
    }

    func testWeekday() {
        XCTAssertEqual(CalendarDay(year: 2026, month: 10, day: 31).isoWeekday, 6) // Saturday
        XCTAssertEqual(CalendarDay(year: 2026, month: 10, day: 26).isoWeekday, 1) // Monday
        XCTAssertEqual(CalendarDay(year: 2026, month: 11, day: 1).weekStart, CalendarDay(year: 2026, month: 10, day: 26))
    }

    func testDayFromDateRespectsTimeZone() {
        // 2026-10-31T03:00Z is still Oct 30 in Los Angeles and Oct 31 in Tokyo.
        let date = ISOTimestamp.date(milliseconds: ISOTimestamp.parseMilliseconds("2026-10-31T03:00:00.000Z")!)
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(CalendarDay(date, calendar: la).string, "2026-10-30")
        XCTAssertEqual(CalendarDay(date, calendar: tokyo).string, "2026-10-31")
    }

    func testDSTDaysAreCalendarDays() {
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-11-01 is a 25-hour day in New York; day arithmetic must still step by one date.
        let d = CalendarDay(year: 2026, month: 11, day: 1)
        XCTAssertEqual(d.adding(days: 1).string, "2026-11-02")
        let start = d.startDate(in: ny), next = d.adding(days: 1).startDate(in: ny)
        XCTAssertEqual(next.timeIntervalSince(start), 25 * 3600)
        XCTAssertEqual(CalendarDay(start.addingTimeInterval(24.5 * 3600), calendar: ny), d)
    }

    func testISOTimestampFormatting() {
        XCTAssertEqual(ISOTimestamp.format(milliseconds: 0), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(ISOTimestamp.format(milliseconds: 1_793_435_340_123), "2026-10-31T08:29:00.123Z")
        XCTAssertEqual(ISOTimestamp.format(milliseconds: -1), "1969-12-31T23:59:59.999Z")
        for ms: Int64 in [0, 1, 999, 1_793_435_340_123, 951_782_400_000, -86_400_001] {
            XCTAssertEqual(ISOTimestamp.parseMilliseconds(ISOTimestamp.format(milliseconds: ms)), ms)
        }
        XCTAssertEqual(ISOTimestamp.parseMilliseconds("2026-10-31T08:29:00Z"), 1_793_435_340_000)
        XCTAssertNil(ISOTimestamp.parseMilliseconds("2026-10-31 08:29:00"))
    }

    func testTruncationMatchesStorage() {
        let d = Date(timeIntervalSince1970: 1_793_435_340.123_9)
        XCTAssertEqual(ISOTimestamp.milliseconds(d), 1_793_435_340_123)
        XCTAssertEqual(ISOTimestamp.milliseconds(ISOTimestamp.truncated(d)), 1_793_435_340_123)
    }
}
