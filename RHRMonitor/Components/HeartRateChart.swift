import SwiftUI
import Charts
import HeartRateKit

/// Heart rate line chart. Lines are broken at gaps (separate series per contiguous segment) and
/// gaps are shaded, so missing data is never drawn as if it had been measured.
struct HeartRateChart: View {
    let series: ChartSeries
    let xDomain: ClosedRange<Date>
    /// When set, the chart scrolls horizontally showing this many seconds at a time.
    var visibleSeconds: TimeInterval? = nil
    @Binding var scrollPosition: Date
    /// Optional vertical marker (e.g. end of the resting settling period).
    var marker: (date: Date, label: String)? = nil

    @State private var selectedDate: Date?

    private var yDomain: ClosedRange<Double> {
        let lo = series.points.map { Double($0.minBPM) }.min() ?? 50
        let hi = series.points.map { Double($0.maxBPM) }.max() ?? 90
        var low = (lo - 5).rounded(.down)
        var high = (hi + 5).rounded(.up)
        if high - low < 20 {
            let mid = (high + low) / 2
            low = mid - 10
            high = mid + 10
        }
        return max(20, low)...min(240, high)
    }

    private var isolatedSegments: Set<Int> {
        var counts: [Int: Int] = [:]
        for p in series.points { counts[p.segment, default: 0] += 1 }
        return Set(counts.filter { $0.value == 1 }.map(\.key))
    }

    private var selectedPoint: ChartPoint? {
        guard let selectedDate, !series.points.isEmpty else { return nil }
        return series.points.min { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        let isolated = isolatedSegments
        let chart = Chart {
            ForEach(Array(series.gaps.enumerated()), id: \.offset) { _, gap in
                RectangleMark(xStart: .value("Gap start", gap.start), xEnd: .value("Gap end", gap.end))
                    .foregroundStyle(Color.gray.opacity(0.18))
            }
            if let marker {
                RuleMark(x: .value("Marker", marker.date))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(marker.label).font(.caption2).foregroundStyle(.secondary)
                    }
            }
            ForEach(series.points) { p in
                LineMark(x: .value("Time", p.timestamp), y: .value("BPM", p.bpm), series: .value("Segment", p.segment))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if isolated.contains(p.segment) {
                    PointMark(x: .value("Time", p.timestamp), y: .value("BPM", p.bpm))
                        .foregroundStyle(Color.red)
                        .symbolSize(16)
                }
            }
            if let sel = selectedPoint {
                RuleMark(x: .value("Selected", sel.timestamp))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .annotation(position: .top, alignment: .center,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 0) {
                            Text("\(Int(sel.bpm.rounded())) BPM").font(.caption.bold())
                            if sel.minBPM != sel.maxBPM {
                                Text("range \(sel.minBPM)–\(sel.maxBPM)").font(.caption2)
                            }
                            Text(sel.timestamp, format: .dateTime.hour().minute().second()).font(.caption2)
                        }
                        .padding(4)
                        .background(Color(.systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartXSelection(value: $selectedDate)
        .chartYAxis { AxisMarks(position: .leading) }

        Group {
            if let visibleSeconds {
                chart
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: visibleSeconds)
                    .chartScrollPosition(x: $scrollPosition)
            } else {
                chart
            }
        }
        .overlay {
            if series.points.isEmpty {
                Text("No heart rate data in this range")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Heart rate chart")
    }
}
