import Foundation

/// One plotted point. When downsampled, `bpm` is the bucket mean and min/max give its range.
public struct ChartPoint: Equatable, Sendable, Identifiable {
    public var id: Int
    /// Contiguous run index; lines must not be drawn across segments (that would hide a gap).
    public var segment: Int
    public var timestamp: Date
    public var bpm: Double
    public var minBPM: Int
    public var maxBPM: Int
}

public struct ChartSeries: Equatable, Sendable {
    public var points: [ChartPoint]
    public var gaps: [TimeGap]
    public var isDownsampled: Bool

    public static let empty = ChartSeries(points: [], gaps: [], isDownsampled: false)
}

public enum ChartDownsampler {
    /// Prepares samples for plotting: filters to `range`, splits at gaps, and buckets by time
    /// when there are more than `maxPoints` samples. Never interpolates across gaps.
    public static func series(from samples: [HeartRatePoint], range: ClosedRange<Date>? = nil, maxPoints: Int = 600,
                              gapThreshold: TimeInterval = GapDetector.defaultThreshold) -> ChartSeries {
        let visible: [HeartRatePoint]
        if let range {
            visible = samples.filter { range.contains($0.timestamp) }
        } else {
            visible = samples
        }
        guard let first = visible.first, let last = visible.last else { return .empty }
        let gaps = GapDetector.gaps(in: visible.map(\.timestamp), threshold: gapThreshold)
        let segments = GapDetector.segments(visible, threshold: gapThreshold, timestamp: \.timestamp)

        var points: [ChartPoint] = []
        let downsample = visible.count > max(maxPoints, 1)
        if !downsample {
            points.reserveCapacity(visible.count)
            for (s, seg) in segments.enumerated() {
                for p in seg {
                    points.append(ChartPoint(id: points.count, segment: s, timestamp: p.timestamp, bpm: Double(p.bpm),
                                             minBPM: p.bpm, maxBPM: p.bpm))
                }
            }
            return ChartSeries(points: points, gaps: gaps, isDownsampled: false)
        }

        let span = max(last.timestamp.timeIntervalSince(first.timestamp), 1)
        let width = span / Double(maxPoints)
        for (s, seg) in segments.enumerated() {
            var bucket: [HeartRatePoint] = []
            var bucketIndex = -1
            func emit() {
                guard !bucket.isEmpty else { return }
                let meanT = bucket.reduce(0) { $0 + $1.timestamp.timeIntervalSince1970 } / Double(bucket.count)
                let meanBPM = Double(bucket.reduce(0) { $0 + $1.bpm }) / Double(bucket.count)
                points.append(ChartPoint(id: points.count, segment: s, timestamp: Date(timeIntervalSince1970: meanT),
                                         bpm: meanBPM, minBPM: bucket.map(\.bpm).min() ?? 0,
                                         maxBPM: bucket.map(\.bpm).max() ?? 0))
                bucket.removeAll(keepingCapacity: true)
            }
            for p in seg {
                let idx = Int(p.timestamp.timeIntervalSince(first.timestamp) / width)
                if idx != bucketIndex { emit(); bucketIndex = idx }
                bucket.append(p)
            }
            emit()
        }
        return ChartSeries(points: points, gaps: gaps, isDownsampled: true)
    }
}

/// In-memory rolling buffer of recent readings for the live chart (independent of recording).
public struct LiveBuffer: Sendable {
    public private(set) var points: [HeartRatePoint] = []
    public let maxAge: TimeInterval

    /// Keeps up to `maxAge` seconds of readings (default 12 hours).
    public init(maxAge: TimeInterval = 12 * 3600) {
        self.maxAge = maxAge
    }

    public mutating func append(_ p: HeartRatePoint) {
        if let last = points.last, p.timestamp < last.timestamp {
            // Out-of-order delivery is unexpected; keep the buffer sorted.
            let i = points.firstIndex { $0.timestamp > p.timestamp } ?? points.endIndex
            points.insert(p, at: i)
        } else {
            points.append(p)
        }
        trim(now: p.timestamp)
    }

    public mutating func replaceAll(with newPoints: [HeartRatePoint]) {
        points = newPoints.sorted { $0.timestamp < $1.timestamp }
    }

    public mutating func removeAll() { points.removeAll() }

    public func since(_ date: Date) -> [HeartRatePoint] {
        // Binary search for the first point at or after `date`.
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return Array(points[lo...])
    }

    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-maxAge)
        // Trim in chunks to keep appends amortized O(1).
        if let first = points.first, first.timestamp < cutoff.addingTimeInterval(-600) {
            points.removeAll { $0.timestamp < cutoff }
        }
    }
}
