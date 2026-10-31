import XCTest
@testable import HeartRateKit

final class RestingHRTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func samples(every interval: TimeInterval, from: TimeInterval, to: TimeInterval, bpm: (TimeInterval) -> Int,
                 skip: ClosedRange<TimeInterval>? = nil, contact: SensorContact = .detected) -> [HeartRateSample] {
        stride(from: from, to: to, by: interval).compactMap { t in
            if let skip, skip.contains(t) { return nil }
            return HeartRateSample(sessionID: "s", timestamp: t0.addingTimeInterval(t), bpm: bpm(t), sensorContact: contact, sourceDevice: "W")
        }
    }

    func testCompleteMeasurementUsesLastThreeMinutes() {
        // Settling minutes at 80 BPM must be ignored; window alternates 55/57.
        let s = samples(every: 1, from: 0, to: 300) { t in t < 120 ? 80 : (Int(t) % 2 == 0 ? 55 : 57) }
        let r = RestingHRCalculator.analyze(samples: s, start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(r.medianBPM, 56)
        XCTAssertEqual(r.meanBPM!, 56, accuracy: 0.01)
        XCTAssertEqual(r.minBPM, 55)
        XCTAssertEqual(r.maxBPM, 57)
        XCTAssertEqual(r.sampleCount, 180)
        XCTAssertGreaterThan(r.coverage, 0.99)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.flags, [])
    }

    func testIrregularSamplingStillCovered() {
        // ~1.7 s spacing: no sampling interval is assumed.
        let s = samples(every: 1.7, from: 0, to: 300) { _ in 60 }
        let r = RestingHRCalculator.analyze(samples: s, start: t0, end: t0.addingTimeInterval(300))
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.medianBPM, 60)
    }

    func testLargeGapFlagsInsufficientCoverage() {
        // 60 s missing inside a 180 s window → 66% coverage < 80%.
        let s = samples(every: 1, from: 0, to: 300, bpm: { _ in 60 }, skip: 150...210)
        let r = RestingHRCalculator.analyze(samples: s, start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(r.coverage, 1 - 62.0 / 180, accuracy: 0.01)
        XCTAssertTrue(r.flags.contains(.insufficientCoverage))
        XCTAssertTrue(r.flags.contains(.largeGap))
        XCTAssertFalse(r.isValid)
        XCTAssertEqual(r.medianBPM, 60, "stats are still reported, just not trusted")
    }

    func testShortGapIsWarningOnly() {
        let s = samples(every: 1, from: 0, to: 300, bpm: { _ in 60 }, skip: 200...231)
        let r = RestingHRCalculator.analyze(samples: s, start: t0, end: t0.addingTimeInterval(300))
        XCTAssertTrue(r.flags.contains(.largeGap))
        XCTAssertTrue(r.isValid)
    }

    func testStoppedEarly() {
        let s = samples(every: 1, from: 0, to: 200) { _ in 60 }
        let r = RestingHRCalculator.analyze(samples: s, start: t0, end: t0.addingTimeInterval(200))
        XCTAssertTrue(r.flags.contains(.stoppedEarly))
        XCTAssertFalse(r.isValid)
    }

    func testNoSamples() {
        let r = RestingHRCalculator.analyze(samples: [], start: t0, end: t0.addingTimeInterval(300))
        XCTAssertEqual(r.flags, [.noSamples])
        XCTAssertNil(r.medianBPM)
        XCTAssertEqual(r.coverage, 0)
        XCTAssertFalse(r.isValid)
    }

    func testNoContactSamplesExcluded() {
        let s = samples(every: 1, from: 0, to: 300, bpm: { _ in 60 }, contact: .notDetected)
        let r = RestingHRCalculator.analyze(samples: s, start: t0, end: t0.addingTimeInterval(300))
        XCTAssertTrue(r.flags.contains(.noSamples))
        XCTAssertTrue(r.flags.contains(.contactLost))
    }

    func testConfigurableCoverageThreshold() {
        let s = samples(every: 1, from: 0, to: 300, bpm: { _ in 60 }, skip: 150...210)
        var p = RestingHRProtocol.standard
        p.minimumCoverage = 0.5
        let r = RestingHRCalculator.analyze(samples: s, start: t0, end: t0.addingTimeInterval(300), settings: p)
        XCTAssertTrue(r.isValid)
    }

    func testPhases() {
        XCTAssertEqual(RestingHRCalculator.phase(start: t0, now: t0.addingTimeInterval(20)), .settling(remaining: 100))
        XCTAssertEqual(RestingHRCalculator.phase(start: t0, now: t0.addingTimeInterval(200)), .measuring(remaining: 100))
        XCTAssertEqual(RestingHRCalculator.phase(start: t0, now: t0.addingTimeInterval(300)), .finished)
    }
}

final class StatsTests: XCTestCase {
    func testBasics() {
        XCTAssertEqual(Stats.median([3, 1, 2]), 2)
        XCTAssertEqual(Stats.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(Stats.median([]))
        XCTAssertEqual(Stats.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9])!, 2.138, accuracy: 0.001)
        XCTAssertNil(Stats.standardDeviation([1]))
        let r = Stats.linearRegression(x: [0, 1, 2, 3], y: [1, 3, 5, 7])!
        XCTAssertEqual(r.slope, 2, accuracy: 1e-9)
        XCTAssertEqual(r.intercept, 1, accuracy: 1e-9)
        XCTAssertEqual(r.rSquared, 1, accuracy: 1e-9)
        XCTAssertEqual(Stats.pearson([1, 2, 3], [3, 2, 1])!, -1, accuracy: 1e-9)
        XCTAssertNil(Stats.pearson([1, 1, 1], [1, 2, 3]))
        XCTAssertEqual(Stats.tCritical95(df: 1), 12.706)
        XCTAssertEqual(Stats.tCritical95(df: 1000), 1.96)
    }
}

final class GapAndChartTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testGapsAndSegments() {
        let ts = [0, 1, 2, 10, 11, 30].map { t0.addingTimeInterval($0) }
        let gaps = GapDetector.gaps(in: ts, threshold: 5)
        XCTAssertEqual(gaps.map(\.duration), [8, 19])
        let segs = GapDetector.segments(ts, threshold: 5) { $0 }
        XCTAssertEqual(segs.map(\.count), [3, 2, 1])
    }

    func testChartNeverBridgesGaps() {
        let pts = [0, 1, 2, 20, 21].map { HeartRatePoint(timestamp: t0.addingTimeInterval($0), bpm: 60) }
        let s = ChartDownsampler.series(from: pts)
        XCTAssertEqual(s.points.map(\.segment), [0, 0, 0, 1, 1])
        XCTAssertEqual(s.gaps.count, 1)
        XCTAssertFalse(s.isDownsampled)
    }

    func testDownsamplingKeepsRangeAndBounds() {
        let pts = (0..<3600).map { HeartRatePoint(timestamp: t0.addingTimeInterval(Double($0)), bpm: 50 + $0 % 40) }
        let s = ChartDownsampler.series(from: pts, maxPoints: 100)
        XCTAssertTrue(s.isDownsampled)
        XCTAssertLessThanOrEqual(s.points.count, 101)
        XCTAssertEqual(s.points.map(\.minBPM).min(), 50)
        XCTAssertEqual(s.points.map(\.maxBPM).max(), 89)
        XCTAssertEqual(Set(s.points.map(\.segment)), [0])
    }

    func testRangeFilter() {
        let pts = (0..<100).map { HeartRatePoint(timestamp: t0.addingTimeInterval(Double($0)), bpm: 60) }
        let s = ChartDownsampler.series(from: pts, range: t0.addingTimeInterval(40)...t0.addingTimeInterval(99))
        XCTAssertEqual(s.points.count, 60)
    }

    func testLiveBuffer() {
        var b = LiveBuffer(maxAge: 60)
        for i in 0..<1000 { b.append(HeartRatePoint(timestamp: t0.addingTimeInterval(Double(i)), bpm: 60)) }
        XCTAssertLessThanOrEqual(b.points.count, 61 + 600)
        XCTAssertEqual(b.since(t0.addingTimeInterval(990)).count, 10)
        b.append(HeartRatePoint(timestamp: t0.addingTimeInterval(995.5), bpm: 61))
        XCTAssertEqual(b.points.map(\.timestamp), b.points.map(\.timestamp).sorted())
    }
}

final class TrendTests: XCTestCase {
    let today = CalendarDay(year: 2026, month: 10, day: 31)

    func daily(_ values: [(Int, Double)]) -> [DailyValue] {
        values.map { DailyValue(day: today.adding(days: $0.0), bpm: $0.1) }.sorted { $0.day < $1.day }
    }

    func testDailyValuesSeparateSourcesAndSkipInvalid() {
        let d = today
        let obs = [
            RHRObservation(id: "1", source: .controlled, day: d, timestamp: Date(), bpm: 60),
            RHRObservation(id: "2", source: .controlled, day: d, timestamp: Date(), bpm: 62),
            RHRObservation(id: "3", source: .controlled, day: d.adding(days: -1), timestamp: Date(), bpm: 90, isValid: false),
            RHRObservation(id: "4", source: .whoopOvernight, day: d, timestamp: Date(), bpm: 50),
        ]
        let c = TrendCalculator.dailyValues(obs, source: .controlled)
        XCTAssertEqual(c, [DailyValue(day: d, bpm: 61, count: 2)])
        XCTAssertEqual(TrendCalculator.dailyValues(obs, source: .whoopOvernight).map(\.bpm), [50])
    }

    func testPostureFilter() {
        let obs = [
            RHRObservation(id: "1", source: .controlled, day: today, timestamp: Date(), bpm: 60, posture: .sitting),
            RHRObservation(id: "2", source: .controlled, day: today, timestamp: Date(), bpm: 54, posture: .lyingDown),
        ]
        XCTAssertEqual(TrendCalculator.dailyValues(obs, source: .controlled, posture: .lyingDown).map(\.bpm), [54])
    }

    func testMovingAverageUsesCalendarWindowAndMinimum() {
        // Days -6, -5, -1, 0 present; days in between missing.
        let d = daily([(-6, 60), (-5, 62), (-1, 58), (0, 56)])
        let ma = TrendCalculator.movingAverage(d, windowDays: 7, minimumCount: 3)
        // First day with ≥3 values in its window is day -1 (values -6, -5, -1).
        XCTAssertEqual(ma.first?.day, today.adding(days: -1))
        XCTAssertEqual(ma.first?.bpm ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(ma.last?.day, today)
        XCTAssertEqual(ma.last?.bpm ?? 0, 59, accuracy: 1e-9)
        XCTAssertEqual(ma.last?.count, 4)
    }

    func testSummary() {
        // Steady decline: 70 → 56 over 42 days, one per day.
        let d = daily((0...42).map { (-42 + $0, 70 - Double($0) / 3) })
        let s = TrendCalculator.summary(d, today: today)
        XCTAssertEqual(s.latest?.bpm ?? 0, 56, accuracy: 1e-9)
        XCTAssertEqual(s.average7!, 57, accuracy: 1e-9)
        XCTAssertEqual(s.change30!, -10, accuracy: 1e-9)
        XCTAssertEqual(s.slopePerWeek!, -7.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(s.daysWithDataLast28, 28)
        XCTAssertLessThan(s.baselineDeviation!, 0)
    }

    func testSummaryWithholdsWhenSparse() {
        let s = TrendCalculator.summary(daily([(0, 60), (-2, 61)]), today: today)
        XCTAssertNil(s.average7)
        XCTAssertNil(s.average28)
        XCTAssertNil(s.change30)
        XCTAssertNil(s.slopePerWeek)
        XCTAssertNil(s.baselineDeviation)
        XCTAssertEqual(s.latest?.bpm, 60)
    }

    func testPeriods() {
        let d = daily([(-12, 60), (-11, 62), (-5, 58), (0, 56)])
        let weeks = TrendCalculator.periods(d, by: .week)
        XCTAssertEqual(weeks.map(\.start), [CalendarDay(string: "2026-10-19")!, CalendarDay(string: "2026-10-26")!])
        XCTAssertEqual(weeks[0].mean, 61)
        XCTAssertEqual(weeks[1].mean, 57)
        XCTAssertEqual(weeks[1].changeFromPrevious, -4)
        let months = TrendCalculator.periods(d, by: .month)
        XCTAssertEqual(months.count, 1)
    }
}

final class CorrelationTests: XCTestCase {
    let base = CalendarDay(year: 2026, month: 9, day: 1)

    func testAlcoholNextMorning() {
        var annotations: [Annotation] = []
        var daily: [DailyValue] = []
        for i in 0..<20 {
            let d = base.adding(days: i)
            let drank = i % 2 == 0
            annotations.append(Annotation(day: d, kind: drank ? .alcohol : .caffeine, value: drank ? 2 : 1))
            daily.append(DailyValue(day: d.adding(days: 1), bpm: drank ? 64 : 58))
        }
        let c = CorrelationAnalyzer.compare(.alcohol, annotations: annotations, daily: daily)
        XCTAssertEqual(c.daysWith, 10)
        XCTAssertEqual(c.daysWithout, 10)
        XCTAssertEqual(c.difference!, 6, accuracy: 1e-9)
        XCTAssertEqual(c.strength, .moderate)
        XCTAssertTrue(c.summary.contains("higher"))
        XCTAssertTrue(c.summary.contains("Observational"))
    }

    func testUnloggedDaysAreNotAbsence() {
        // Only days with alcohol were logged → no "without" group → insufficient.
        let annotations = (0..<5).map { Annotation(day: base.adding(days: $0 * 2), kind: .alcohol, value: 1) }
        let daily = (0..<12).map { DailyValue(day: base.adding(days: $0), bpm: 60) }
        let c = CorrelationAnalyzer.compare(.alcohol, annotations: annotations, daily: daily)
        XCTAssertEqual(c.daysWithout, 0)
        XCTAssertEqual(c.strength, .insufficient)
        XCTAssertNil(c.difference)
        XCTAssertTrue(c.summary.hasPrefix("Not enough data"))
    }

    func testSmallSampleIsWeakAndNoisyIntervalMentioned() {
        var annotations: [Annotation] = []
        var daily: [DailyValue] = []
        let values: [Double] = [60, 66, 59, 63, 61, 65]
        for i in 0..<6 {
            let d = base.adding(days: i)
            annotations.append(Annotation(day: d, kind: i < 3 ? .exercise : .note, value: 3))
            daily.append(DailyValue(day: d.adding(days: 1), bpm: values[i]))
        }
        let c = CorrelationAnalyzer.compare(.exercise, annotations: annotations, daily: daily)
        XCTAssertEqual(c.strength, .weak)
        XCTAssertNotNil(c.interval95)
        XCTAssertTrue(c.summary.contains("includes zero"))
    }

    func testStressRequiresHighLevel() {
        let a1 = Annotation(day: base, kind: .stress, value: 2)
        let a2 = Annotation(day: base, kind: .stress, value: 5)
        XCTAssertFalse(CorrelationAnalyzer.isPresent(a1, kind: .stress))
        XCTAssertTrue(CorrelationAnalyzer.isPresent(a2, kind: .stress))
    }

    func testSleepAssociation() {
        let hours: [Double] = [5, 6, 7, 8, 9, 6.5]
        let annotations = hours.enumerated().map { Annotation(day: base.adding(days: $0.offset), kind: .sleep, value: $0.element) }
        let daily = hours.enumerated().map { DailyValue(day: base.adding(days: $0.offset), bpm: 80 - 2 * $0.element) }
        let s = CorrelationAnalyzer.sleepAssociation(annotations: annotations, daily: daily)
        XCTAssertEqual(s.pairs, 6)
        XCTAssertEqual(s.correlation!, -1, accuracy: 1e-9)
        XCTAssertEqual(s.slopePerHour!, -2, accuracy: 1e-9)
        XCTAssertEqual(s.strength, .weak)
        XCTAssertEqual(CorrelationAnalyzer.sleepAssociation(annotations: Array(annotations.prefix(3)), daily: daily).strength, .insufficient)
    }
}
