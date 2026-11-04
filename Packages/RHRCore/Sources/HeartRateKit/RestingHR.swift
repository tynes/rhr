import Foundation

/// Parameters of the standardized resting heart rate measurement.
public struct RestingHRProtocol: Equatable, Sendable, Codable {
    /// Initial settling period excluded from the result.
    public var settleSeconds: TimeInterval
    /// Measurement window that follows the settling period.
    public var windowSeconds: TimeInterval
    /// Minimum fraction of the window that must be covered by samples (0…1).
    public var minimumCoverage: Double
    /// Spacing between samples above which time counts as uncovered.
    public var gapThresholdSeconds: TimeInterval
    /// Minimum number of usable samples in the window.
    public var minimumSamples: Int
    /// A single gap longer than this raises a warning.
    public var largeGapSeconds: TimeInterval

    public init(settleSeconds: TimeInterval = 120, windowSeconds: TimeInterval = 180, minimumCoverage: Double = 0.8,
                gapThresholdSeconds: TimeInterval = GapDetector.defaultThreshold, minimumSamples: Int = 30,
                largeGapSeconds: TimeInterval = 30) {
        self.settleSeconds = settleSeconds
        self.windowSeconds = windowSeconds
        self.minimumCoverage = minimumCoverage
        self.gapThresholdSeconds = gapThresholdSeconds
        self.minimumSamples = minimumSamples
        self.largeGapSeconds = largeGapSeconds
    }

    public static let standard = RestingHRProtocol()

    public var totalSeconds: TimeInterval { settleSeconds + windowSeconds }
}

public enum RestingFlag: String, Codable, Sendable, CaseIterable {
    case noSamples
    case insufficientCoverage
    case tooFewSamples
    case stoppedEarly
    /// Warning only: at least one long gap inside the window.
    case largeGap
    /// Warning only: some samples were excluded because the sensor reported no skin contact.
    case contactLost

    /// Flags that make a measurement invalid (others are warnings).
    public var invalidates: Bool {
        switch self {
        case .noSamples, .insufficientCoverage, .tooFewSamples, .stoppedEarly: return true
        case .largeGap, .contactLost: return false
        }
    }

    public var message: String {
        switch self {
        case .noSamples: return "No heart rate samples in the measurement window."
        case .insufficientCoverage: return "Too much of the measurement window has no data."
        case .tooFewSamples: return "Too few samples in the measurement window."
        case .stoppedEarly: return "Measurement stopped before it finished."
        case .largeGap: return "There was a long gap in the data."
        case .contactLost: return "Some samples were dropped because the strap reported no skin contact."
        }
    }
}

public struct RestingHRResult: Equatable, Sendable, Codable {
    /// Primary metric: median BPM over the measurement window.
    public var medianBPM: Double?
    public var meanBPM: Double?
    public var minBPM: Int?
    public var maxBPM: Int?
    public var sdBPM: Double?
    public var sampleCount: Int
    /// Fraction of the measurement window covered by samples (0…1).
    public var coverage: Double
    public var largestGapSeconds: TimeInterval
    public var flags: [RestingFlag]

    public var isValid: Bool { medianBPM != nil && !flags.contains(where: { $0.invalidates }) }

    public init(medianBPM: Double?, meanBPM: Double?, minBPM: Int?, maxBPM: Int?, sdBPM: Double?, sampleCount: Int,
                coverage: Double, largestGapSeconds: TimeInterval, flags: [RestingFlag]) {
        self.medianBPM = medianBPM
        self.meanBPM = meanBPM
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.sdBPM = sdBPM
        self.sampleCount = sampleCount
        self.coverage = coverage
        self.largestGapSeconds = largestGapSeconds
        self.flags = flags
    }
}

/// A completed standardized resting HR measurement.
public struct RestingMeasurement: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var sessionID: String
    public var startedAt: Date
    /// Local calendar day when the measurement started.
    public var day: CalendarDay
    public var timeZoneIdentifier: String
    public var posture: Posture
    public var settings: RestingHRProtocol
    public var result: RestingHRResult
    public var notes: String

    public init(id: String = UUID().uuidString, sessionID: String, startedAt: Date, day: CalendarDay,
                timeZoneIdentifier: String, posture: Posture, settings: RestingHRProtocol, result: RestingHRResult,
                notes: String = "") {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = ISOTimestamp.truncated(startedAt)
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.posture = posture
        self.settings = settings
        self.result = result
        self.notes = notes
    }
}

public enum RestingHRCalculator {
    /// Analyzes samples from a resting session.
    ///
    /// - Parameters:
    ///   - samples: the session's samples (any order).
    ///   - start: when the measurement started.
    ///   - end: when it actually ended (stopped by the user or completed).
    public static func analyze(samples: [HeartRateSample], start: Date, end: Date,
                               settings: RestingHRProtocol = .standard) -> RestingHRResult {
        let windowStart = start.addingTimeInterval(settings.settleSeconds)
        let windowEnd = start.addingTimeInterval(settings.totalSeconds)
        var flags: [RestingFlag] = []
        if end < windowEnd.addingTimeInterval(-1) { flags.append(.stoppedEarly) }

        let inWindow = samples
            .filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd && HeartRateMeasurementParser.plausibleRange.contains($0.bpm) }
            .sorted { $0.timestamp < $1.timestamp }
        let usable = inWindow.filter { $0.sensorContact != .notDetected }
        if usable.count < inWindow.count { flags.append(.contactLost) }

        let times = usable.map(\.timestamp)
        let gaps = GapDetector.gaps(in: times, windowStart: windowStart, windowEnd: windowEnd,
                                    threshold: settings.gapThresholdSeconds)
        let uncovered = gaps.reduce(0) { $0 + $1.duration }
        let coverage = settings.windowSeconds > 0 ? max(0, min(1, 1 - uncovered / settings.windowSeconds)) : 0
        let largest = gaps.map(\.duration).max() ?? 0

        let bpms = usable.map { Double($0.bpm) }
        if bpms.isEmpty {
            flags.append(.noSamples)
        } else {
            if usable.count < settings.minimumSamples { flags.append(.tooFewSamples) }
            if coverage < settings.minimumCoverage { flags.append(.insufficientCoverage) }
            if largest > settings.largeGapSeconds { flags.append(.largeGap) }
        }

        return RestingHRResult(
            medianBPM: Stats.median(bpms),
            meanBPM: Stats.mean(bpms),
            minBPM: usable.map(\.bpm).min(),
            maxBPM: usable.map(\.bpm).max(),
            sdBPM: Stats.standardDeviation(bpms),
            sampleCount: usable.count,
            coverage: coverage,
            largestGapSeconds: largest,
            flags: flags
        )
    }

    public enum Phase: Equatable, Sendable {
        case settling(remaining: TimeInterval)
        case measuring(remaining: TimeInterval)
        case finished
    }

    /// Countdown phase for a measurement that started at `start`.
    public static func phase(start: Date, now: Date, settings: RestingHRProtocol = .standard) -> Phase {
        let elapsed = now.timeIntervalSince(start)
        if elapsed < settings.settleSeconds { return .settling(remaining: settings.settleSeconds - elapsed) }
        if elapsed < settings.totalSeconds { return .measuring(remaining: settings.totalSeconds - elapsed) }
        return .finished
    }
}
