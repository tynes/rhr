import Foundation

/// Where a resting heart rate value came from. Sources are never merged into one series.
public enum RHRSource: String, Codable, Sendable, CaseIterable, Identifiable {
    /// This app's standardized 5-minute measurement (median of the last 3 minutes).
    case controlled
    /// WHOOP's proprietary overnight resting HR, imported from a WHOOP data export.
    case whoopOvernight
    /// Apple Health daily resting heart rate (reserved for the optional HealthKit import).
    case appleHealth

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .controlled: return "5-min resting session"
        case .whoopOvernight: return "WHOOP overnight (imported)"
        case .appleHealth: return "Apple Health"
        }
    }

    public var methodDescription: String {
        switch self {
        case .controlled:
            return "Median BPM over minutes 3–5 of a seated or lying measurement taken with this app."
        case .whoopOvernight:
            return "WHOOP's own overnight resting heart rate, calculated by WHOOP during sleep. Not directly comparable to a daytime measurement."
        case .appleHealth:
            return "Apple Health's daily resting heart rate estimate."
        }
    }
}

/// A resting HR value from an imported source (one per day per source).
public struct ImportedRestingHR: Equatable, Sendable, Codable {
    public var source: RHRSource
    public var day: CalendarDay
    public var bpm: Double
    public var importedAt: Date
    public var notes: String

    public init(source: RHRSource, day: CalendarDay, bpm: Double, importedAt: Date = Date(), notes: String = "") {
        self.source = source
        self.day = day
        self.bpm = bpm
        self.importedAt = ISOTimestamp.truncated(importedAt)
        self.notes = notes
    }
}

/// A single plotted resting HR observation from any source.
public struct RHRObservation: Equatable, Sendable, Identifiable {
    public var id: String
    public var source: RHRSource
    public var day: CalendarDay
    public var timestamp: Date
    public var bpm: Double
    public var posture: Posture?
    public var isValid: Bool
    public var notes: String

    public init(id: String, source: RHRSource, day: CalendarDay, timestamp: Date, bpm: Double, posture: Posture? = nil,
                isValid: Bool = true, notes: String = "") {
        self.id = id
        self.source = source
        self.day = day
        self.timestamp = timestamp
        self.bpm = bpm
        self.posture = posture
        self.isValid = isValid
        self.notes = notes
    }

    public init(_ m: RestingMeasurement) {
        self.init(id: m.id, source: .controlled, day: m.day, timestamp: m.startedAt, bpm: m.result.medianBPM ?? 0,
                  posture: m.posture, isValid: m.result.isValid, notes: m.notes)
    }

    public init(_ i: ImportedRestingHR, calendar: Calendar = .current) {
        self.init(id: "\(i.source.rawValue)-\(i.day.string)", source: i.source, day: i.day,
                  timestamp: i.day.startDate(in: calendar).addingTimeInterval(7 * 3600), bpm: i.bpm, notes: i.notes)
    }
}

public struct DailyValue: Equatable, Sendable {
    public var day: CalendarDay
    /// Mean of the day's valid observations (usually exactly one).
    public var bpm: Double
    public var count: Int

    public init(day: CalendarDay, bpm: Double, count: Int = 1) {
        self.day = day
        self.bpm = bpm
        self.count = count
    }
}

public struct MovingAveragePoint: Equatable, Sendable {
    public var day: CalendarDay
    public var bpm: Double
    /// Number of days with data inside the window.
    public var count: Int
}

public struct PeriodSummary: Equatable, Sendable {
    public var start: CalendarDay
    public var mean: Double
    public var days: Int
    /// Change versus the previous period that had data, if any.
    public var changeFromPrevious: Double?
}

public struct TrendSummary: Equatable, Sendable {
    public var latest: DailyValue?
    public var average7: Double?
    public var average28: Double?
    /// Mean of the last 7 days minus the mean of the 7 days ending 30 days earlier.
    public var change30: Double?
    /// Least-squares slope over all supplied days, in BPM per week.
    public var slopePerWeek: Double?
    /// Latest value minus the mean of the 28 days before it.
    public var baselineDeviation: Double?
    public var baselineZScore: Double?
    /// Standard deviation of daily values over the last 28 days (lower = more consistent).
    public var consistencySD: Double?
    public var daysWithDataLast28: Int
}

/// Deterministic trend calculations over calendar days. Missing days are never filled in:
/// windows simply contain fewer values, and a statistic is withheld below its minimum count.
public enum TrendCalculator {
    public static let minimumFor7Day = 3
    public static let minimumFor28Day = 7

    public static func dailyValues(_ observations: [RHRObservation], source: RHRSource,
                                   posture: Posture? = nil) -> [DailyValue] {
        var byDay: [CalendarDay: [Double]] = [:]
        for o in observations where o.source == source && o.isValid && o.bpm > 0 {
            if let posture, o.posture != posture { continue }
            byDay[o.day, default: []].append(o.bpm)
        }
        return byDay.keys.sorted().map { d in
            let v = byDay[d]!
            return DailyValue(day: d, bpm: v.reduce(0, +) / Double(v.count), count: v.count)
        }
    }

    /// Trailing calendar-window mean for each day in `from…through` that has enough data.
    public static func movingAverage(_ daily: [DailyValue], windowDays: Int, minimumCount: Int,
                                     from: CalendarDay? = nil, through: CalendarDay? = nil) -> [MovingAveragePoint] {
        guard let firstDay = daily.first?.day, let lastDay = daily.last?.day else { return [] }
        let start = from ?? firstDay
        let end = through ?? lastDay
        guard start <= end else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: daily.map { ($0.day.julianDay, $0.bpm) })
        var out: [MovingAveragePoint] = []
        for j in start.julianDay...end.julianDay {
            var sum = 0.0, n = 0
            for k in (j - windowDays + 1)...j {
                if let v = lookup[k] { sum += v; n += 1 }
            }
            if n >= minimumCount { out.append(MovingAveragePoint(day: CalendarDay(julianDay: j), bpm: sum / Double(n), count: n)) }
        }
        return out
    }

    /// Mean of daily values in the `days`-long window ending on `end` (inclusive).
    public static func windowMean(_ daily: [DailyValue], ending end: CalendarDay, days: Int, minimumCount: Int) -> Double? {
        let start = end.adding(days: -(days - 1))
        let values = daily.filter { $0.day >= start && $0.day <= end }.map(\.bpm)
        return values.count >= minimumCount ? Stats.mean(values) : nil
    }

    public static func summary(_ daily: [DailyValue], today: CalendarDay) -> TrendSummary {
        let upToToday = daily.filter { $0.day <= today }
        let latest = upToToday.last
        let last28 = upToToday.filter { $0.day > today.adding(days: -28) }

        var deviation: Double?
        var z: Double?
        if let latest {
            let base = upToToday.filter { $0.day < latest.day && $0.day >= latest.day.adding(days: -28) }.map(\.bpm)
            if base.count >= minimumFor28Day, let m = Stats.mean(base) {
                deviation = latest.bpm - m
                if let sd = Stats.standardDeviation(base), sd > 0 { z = (latest.bpm - m) / sd }
            }
        }

        var slope: Double?
        if upToToday.count >= 5, let f = upToToday.first, let l = upToToday.last, l.day.days(since: f.day) >= 14 {
            let x = upToToday.map { Double($0.day.julianDay) }
            let y = upToToday.map(\.bpm)
            slope = Stats.linearRegression(x: x, y: y).map { $0.slope * 7 }
        }

        let recent = windowMean(upToToday, ending: today, days: 7, minimumCount: minimumFor7Day)
        let earlier = windowMean(upToToday, ending: today.adding(days: -30), days: 7, minimumCount: minimumFor7Day)

        return TrendSummary(
            latest: latest,
            average7: recent,
            average28: windowMean(upToToday, ending: today, days: 28, minimumCount: minimumFor28Day),
            change30: (recent != nil && earlier != nil) ? recent! - earlier! : nil,
            slopePerWeek: slope,
            baselineDeviation: deviation,
            baselineZScore: z,
            consistencySD: last28.count >= 5 ? Stats.standardDeviation(last28.map(\.bpm)) : nil,
            daysWithDataLast28: last28.count
        )
    }

    public enum Period: Sendable { case week, month }

    /// Mean per ISO week (Monday start) or calendar month, with change versus the previous period.
    public static func periods(_ daily: [DailyValue], by period: Period) -> [PeriodSummary] {
        var groups: [CalendarDay: [Double]] = [:]
        for d in daily {
            let key = period == .week ? d.day.weekStart : d.day.monthStart
            groups[key, default: []].append(d.bpm)
        }
        var out: [PeriodSummary] = []
        for key in groups.keys.sorted() {
            let v = groups[key]!
            let m = v.reduce(0, +) / Double(v.count)
            out.append(PeriodSummary(start: key, mean: m, days: v.count, changeFromPrevious: out.last.map { m - $0.mean }))
        }
        return out
    }
}
