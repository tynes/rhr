import Foundation

/// A period with no heart rate samples.
public struct TimeGap: Equatable, Sendable, Codable {
    public var start: Date
    public var end: Date
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Finds gaps between consecutive samples. No sampling rate is assumed; a gap is any spacing
/// longer than `threshold` seconds.
public enum GapDetector {
    /// Default gap threshold. Standard HR sensors typically notify about once a second.
    public static let defaultThreshold: TimeInterval = 5

    /// Gaps between consecutive timestamps (input must be sorted ascending).
    public static func gaps(in timestamps: [Date], threshold: TimeInterval = defaultThreshold) -> [TimeGap] {
        guard timestamps.count >= 2 else { return [] }
        var out: [TimeGap] = []
        for i in 1..<timestamps.count where timestamps[i].timeIntervalSince(timestamps[i - 1]) > threshold {
            out.append(TimeGap(start: timestamps[i - 1], end: timestamps[i]))
        }
        return out
    }

    /// Gaps inside `[windowStart, windowEnd]`, including a missing start or end of the window.
    public static func gaps(in timestamps: [Date], windowStart: Date, windowEnd: Date,
                            threshold: TimeInterval = defaultThreshold) -> [TimeGap] {
        let inside = timestamps.filter { $0 >= windowStart && $0 <= windowEnd }
        guard let first = inside.first, let last = inside.last else {
            return windowEnd > windowStart ? [TimeGap(start: windowStart, end: windowEnd)] : []
        }
        var out: [TimeGap] = []
        if first.timeIntervalSince(windowStart) > threshold { out.append(TimeGap(start: windowStart, end: first)) }
        out += gaps(in: inside, threshold: threshold)
        if windowEnd.timeIntervalSince(last) > threshold { out.append(TimeGap(start: last, end: windowEnd)) }
        return out
    }

    /// Splits items into contiguous runs, breaking wherever spacing exceeds `threshold`.
    public static func segments<T>(_ items: [T], threshold: TimeInterval = defaultThreshold,
                                   timestamp: (T) -> Date) -> [[T]] {
        var result: [[T]] = []
        var current: [T] = []
        var previous: Date?
        for item in items {
            let t = timestamp(item)
            if let p = previous, t.timeIntervalSince(p) > threshold, !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(item)
            previous = t
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
