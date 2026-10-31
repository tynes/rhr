import Foundation

/// A calendar date (no time, no time zone), e.g. 2026-10-31.
///
/// Days are resolved from instants using the user's calendar/time zone at the moment of
/// measurement, then stored as plain dates so trends use calendar-day windows that do not shift
/// when the user travels or DST changes.
public struct CalendarDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses `yyyy-MM-dd` (and tolerates a trailing time, e.g. `2026-01-02 07:30:00`).
    public init?(string: String) {
        let head = string.trimmingCharacters(in: .whitespaces).prefix(10)
        let parts = head.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let candidate = CalendarDay(year: y, month: m, day: d)
        // Reject impossible dates such as 2026-02-31.
        guard CalendarDay(julianDay: candidate.julianDay) == candidate else { return nil }
        self = candidate
    }

    /// Days since 1970-01-01 (proleptic Gregorian), using Howard Hinnant's days_from_civil.
    public var julianDay: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public init(julianDay z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: m <= 2 ? y + 1 : y, month: m, day: d)
    }

    public func adding(days: Int) -> CalendarDay { CalendarDay(julianDay: julianDay + days) }

    public func days(since other: CalendarDay) -> Int { julianDay - other.julianDay }

    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var isoWeekday: Int {
        // 1970-01-01 was a Thursday (ISO 4).
        let r = ((julianDay % 7) + 7) % 7
        return ((r + 3) % 7) + 1
    }

    /// The Monday that starts this day's ISO week.
    public var weekStart: CalendarDay { adding(days: -(isoWeekday - 1)) }

    public var monthStart: CalendarDay { CalendarDay(year: year, month: month, day: 1) }

    /// Midnight at the start of this day in `calendar`'s time zone.
    public func startDate(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    public var string: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { string }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool { lhs.julianDay < rhs.julianDay }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = CalendarDay(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad day \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

/// Millisecond-precision UTC timestamps, formatted as ISO 8601 (`2026-10-31T08:29:00.123Z`).
///
/// Implemented with integer arithmetic so export is fast, locale-independent and exactly
/// reversible.
public enum ISOTimestamp {
    public static func milliseconds(_ date: Date) -> Int64 {
        // The small epsilon makes ms → Date → ms round-trip exactly despite binary floating point
        // (e.g. 1793435340.123 × 1000 can evaluate to …122.99999).
        Int64((date.timeIntervalSince1970 * 1000 + 0.001).rounded(.down))
    }

    public static func date(milliseconds ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// Drops sub-millisecond precision so in-memory values equal what the database stores.
    public static func truncated(_ date: Date) -> Date { self.date(milliseconds: milliseconds(date)) }

    public static func format(_ date: Date) -> String { format(milliseconds: milliseconds(date)) }

    public static func format(milliseconds ms: Int64) -> String {
        var days = ms / 86_400_000
        var rem = ms % 86_400_000
        if rem < 0 { rem += 86_400_000; days -= 1 }
        let day = CalendarDay(julianDay: Int(days))
        let h = rem / 3_600_000
        let m = (rem / 60_000) % 60
        let s = (rem / 1000) % 60
        let f = rem % 1000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      day.year, day.month, day.day, Int(h), Int(m), Int(s), Int(f))
    }

    /// Parses `yyyy-MM-ddTHH:mm:ss(.SSS)Z`. Returns nil for other shapes.
    public static func parseMilliseconds(_ string: String) -> Int64? {
        let chars = Array(string.utf8)
        guard chars.count >= 20, chars.last == UInt8(ascii: "Z"),
              let day = CalendarDay(string: String(string.prefix(10))) else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? { Int(String(decoding: chars[a..<b], as: UTF8.self)) }
        guard let h = num(11, 13), let m = num(14, 16), let s = num(17, 19) else { return nil }
        var frac = 0
        if chars.count > 20, chars[19] == UInt8(ascii: ".") {
            let digits = String(decoding: chars[20..<(chars.count - 1)], as: UTF8.self)
            guard !digits.isEmpty, let v = Int(digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)) else { return nil }
            frac = v
        }
        return Int64(day.julianDay) * 86_400_000 + Int64(h) * 3_600_000 + Int64(m) * 60_000 + Int64(s) * 1000 + Int64(frac)
    }
}
