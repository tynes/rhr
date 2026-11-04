import Foundation

public enum AnnotationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case caffeine
    case alcohol
    case sleep
    case exercise
    case stress
    case travel
    case illness
    case note

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .caffeine: return "Caffeine"
        case .alcohol: return "Alcohol"
        case .sleep: return "Sleep"
        case .exercise: return "Exercise"
        case .stress: return "Stress"
        case .travel: return "Travel"
        case .illness: return "Illness"
        case .note: return "Note"
        }
    }

    public var systemImage: String {
        switch self {
        case .caffeine: return "cup.and.saucer.fill"
        case .alcohol: return "wineglass.fill"
        case .sleep: return "bed.double.fill"
        case .exercise: return "figure.run"
        case .stress: return "brain.head.profile"
        case .travel: return "airplane"
        case .illness: return "thermometer.medium"
        case .note: return "note.text"
        }
    }

    /// Meaning of `Annotation.value` for this kind, if any.
    public var valueDescription: String? {
        switch self {
        case .caffeine: return "servings"
        case .alcohol: return "drinks"
        case .sleep: return "hours slept (night before this day)"
        case .exercise: return "intensity 1–5"
        case .stress: return "level 1–5"
        case .travel, .illness, .note: return nil
        }
    }
}

/// A behavioral observation attached to a calendar day (and optionally a recording session).
///
/// Convention: behaviors such as caffeine, alcohol and exercise are logged on the day they
/// happened; sleep is logged on the morning after (the day whose resting HR it precedes).
public struct Annotation: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var day: CalendarDay
    public var createdAt: Date
    public var sessionID: String?
    public var kind: AnnotationKind
    public var value: Double?
    public var text: String

    public init(id: String = UUID().uuidString, day: CalendarDay, createdAt: Date = Date(), sessionID: String? = nil,
                kind: AnnotationKind, value: Double? = nil, text: String = "") {
        self.id = id
        self.day = day
        self.createdAt = ISOTimestamp.truncated(createdAt)
        self.sessionID = sessionID
        self.kind = kind
        self.value = value
        self.text = text
    }

    public var summary: String {
        var parts = [kind.label]
        if let value {
            let v = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            switch kind {
            case .sleep: parts.append("\(v) h")
            case .exercise: parts.append("intensity \(v)")
            case .stress: parts.append("level \(v)")
            case .alcohol: parts.append("\(v) drink\(value == 1 ? "" : "s")")
            case .caffeine: parts.append("\(v) serving\(value == 1 ? "" : "s")")
            default: parts.append(v)
            }
        }
        if !text.isEmpty { parts.append("“\(text)”") }
        return parts.joined(separator: " · ")
    }
}

public enum EvidenceStrength: String, Sendable, Equatable {
    /// Too few observations to say anything.
    case insufficient
    /// Some data, but easily explained by chance or other factors.
    case weak
    /// Enough data for a tentative pattern. Still observational.
    case moderate
}

public struct BehaviorComparison: Equatable, Sendable {
    public var kind: AnnotationKind
    /// Days between the behavior and the resting HR it is compared with.
    public var lagDays: Int
    public var daysWith: Int
    public var daysWithout: Int
    public var meanWith: Double?
    public var meanWithout: Double?
    /// meanWith − meanWithout.
    public var difference: Double?
    /// Approximate 95% interval for the difference (Welch).
    public var interval95: ClosedRange<Double>?
    public var strength: EvidenceStrength
    public var summary: String
}

public struct SleepAssociation: Equatable, Sendable {
    public var pairs: Int
    public var correlation: Double?
    /// Change in resting HR per extra hour of sleep.
    public var slopePerHour: Double?
    public var strength: EvidenceStrength
    public var summary: String
}

/// Simple lagged comparisons between logged behaviors and later resting heart rate.
///
/// These are observational associations, not causal effects. "Without" days are only days on
/// which the user logged *something* else — a day with no annotations at all is treated as
/// unknown rather than as "didn't happen".
public enum CorrelationAnalyzer {
    public static let minimumPerGroup = 3
    public static let moderatePerGroup = 8

    /// Whether an annotation counts as the behavior being present.
    static func isPresent(_ a: Annotation, kind: AnnotationKind) -> Bool {
        guard a.kind == kind else { return false }
        switch kind {
        case .stress: return (a.value ?? 0) >= 4 // "high stress"
        case .alcohol, .caffeine: return (a.value ?? 1) > 0
        default: return true
        }
    }

    public static func compare(_ kind: AnnotationKind, annotations: [Annotation], daily: [DailyValue],
                               lagDays: Int = 1) -> BehaviorComparison {
        let rhr = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.bpm) })
        let loggedDays = Set(annotations.map(\.day))
        let presentDays = Set(annotations.filter { isPresent($0, kind: kind) }.map(\.day))
        var with: [Double] = [], without: [Double] = []
        for d in loggedDays.sorted() {
            guard let v = rhr[d.adding(days: lagDays)] else { continue }
            if presentDays.contains(d) { with.append(v) } else { without.append(v) }
        }
        let mw = Stats.mean(with), mo = Stats.mean(without)
        let diff = (mw != nil && mo != nil) ? mw! - mo! : nil

        var interval: ClosedRange<Double>?
        if let diff, with.count >= 2, without.count >= 2,
           let s1 = Stats.standardDeviation(with), let s2 = Stats.standardDeviation(without) {
            let v1 = s1 * s1 / Double(with.count), v2 = s2 * s2 / Double(without.count)
            let se = (v1 + v2).squareRoot()
            if se > 0 {
                let df = (v1 + v2) * (v1 + v2) / (v1 * v1 / Double(with.count - 1) + v2 * v2 / Double(without.count - 1))
                let t = Stats.tCritical95(df: df)
                interval = (diff - t * se)...(diff + t * se)
            } else {
                interval = diff...diff
            }
        }

        let minCount = min(with.count, without.count)
        let strength: EvidenceStrength = minCount < minimumPerGroup ? .insufficient : (minCount < moderatePerGroup ? .weak : .moderate)
        let when = lagDays == 0 ? "the same day" : (lagDays == 1 ? "the next morning" : "\(lagDays) days later")
        let summary: String
        if strength == .insufficient || diff == nil {
            summary = "Not enough data yet: \(with.count) day(s) with \(kind.label.lowercased()) and \(without.count) logged day(s) without, each with a resting HR \(when). Need at least \(minimumPerGroup) of each."
        } else {
            let direction = diff! >= 0 ? "higher" : "lower"
            var s = String(format: "Resting HR %@ averaged %.1f BPM %@ after days with %@ (n=%d) than after logged days without (n=%d).",
                           when, abs(diff!), direction, kind.label.lowercased(), with.count, without.count)
            if let interval, interval.lowerBound <= 0, interval.upperBound >= 0 {
                s += " The range of plausible differences includes zero, so this may be noise."
            }
            s += strength == .weak ? " Small sample — treat as a hint, not a finding." : " Observational only; other factors may explain it."
            summary = s
        }
        return BehaviorComparison(kind: kind, lagDays: lagDays, daysWith: with.count, daysWithout: without.count,
                                  meanWith: mw, meanWithout: mo, difference: diff, interval95: interval,
                                  strength: strength, summary: summary)
    }

    /// Sleep hours logged on day D versus resting HR on day D.
    public static func sleepAssociation(annotations: [Annotation], daily: [DailyValue]) -> SleepAssociation {
        let rhr = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.bpm) })
        var hoursByDay: [CalendarDay: Double] = [:]
        for a in annotations where a.kind == .sleep {
            if let v = a.value { hoursByDay[a.day] = v }
        }
        var x: [Double] = [], y: [Double] = []
        for (d, h) in hoursByDay.sorted(by: { $0.key < $1.key }) {
            if let v = rhr[d] { x.append(h); y.append(v) }
        }
        let r = Stats.pearson(x, y)
        let slope = Stats.linearRegression(x: x, y: y)?.slope
        let strength: EvidenceStrength = x.count < 5 ? .insufficient : (x.count < 15 ? .weak : .moderate)
        let summary: String
        if strength == .insufficient || r == nil {
            summary = "Not enough data yet: \(x.count) day(s) with both logged sleep and a resting HR. Need at least 5 with varying sleep."
        } else {
            summary = String(format: "Across %d days, each extra hour of sleep went with a %.1f BPM %@ resting HR (r = %.2f). %@",
                             x.count, abs(slope ?? 0), (slope ?? 0) <= 0 ? "lower" : "higher", r!,
                             strength == .weak ? "Small sample — treat as a hint." : "Observational only.")
        }
        return SleepAssociation(pairs: x.count, correlation: r, slopePerHour: slope, strength: strength, summary: summary)
    }
}
