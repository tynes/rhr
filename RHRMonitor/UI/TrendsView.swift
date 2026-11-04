import SwiftUI
import Charts
import HeartRateKit
import HeartRateStore

enum TrendRange: String, CaseIterable, Identifiable {
    case week = "7D", month = "30D", quarter = "90D", year = "1Y", all = "All"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        case .all: return nil
        }
    }
}

enum PostureFilter: String, CaseIterable, Identifiable {
    case all = "All", sitting = "Sitting", lying = "Lying"
    var id: String { rawValue }
    var posture: Posture? {
        switch self {
        case .all: return nil
        case .sitting: return .sitting
        case .lying: return .lyingDown
        }
    }
}

/// Screen C — long-term resting heart rate trends, annotations and insights.
struct TrendsView: View {
    @Environment(AppModel.self) private var model

    @State private var range: TrendRange = .month
    @State private var postureFilter: PostureFilter = .all
    @State private var enabledSources: Set<RHRSource> = [.controlled, .whoopOvernight, .appleHealth]
    @State private var observations: [RHRObservation] = []
    @State private var annotations: [Annotation] = []
    @State private var selectedDate: Date?
    @State private var editorKind: AnnotationKind?
    @State private var showEditor = false
    @State private var toast: String?
    @State private var lastQuickLogged: Annotation?

    private var today: CalendarDay { CalendarDay(Date()) }

    private var startDay: CalendarDay {
        if let d = range.days { return today.adding(days: -(d - 1)) }
        let first = observations.map(\.day).min() ?? today.adding(days: -29)
        return min(first, today.adding(days: -6))
    }

    private var availableSources: [RHRSource] {
        RHRSource.allCases.filter { s in s == .controlled || observations.contains { $0.source == s } }
    }

    /// The series used for averages and statistics: controlled measurements when present.
    private var primarySource: RHRSource {
        if observations.contains(where: { $0.source == .controlled && $0.isValid }) || !enabledSources.contains(.whoopOvernight) {
            return .controlled
        }
        return availableSources.first(where: { $0 != .controlled && enabledSources.contains($0) }) ?? .controlled
    }

    private func daily(_ source: RHRSource) -> [DailyValue] {
        TrendCalculator.dailyValues(observations, source: source, posture: source == .controlled ? postureFilter.posture : nil)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    chart.frame(height: 240)
                    legend
                    if let sel = selectedDate { selectionDetail(CalendarDay(sel)) }
                }
                Section("Show") {
                    ForEach(availableSources) { source in
                        Toggle(isOn: Binding(get: { enabledSources.contains(source) },
                                             set: { on in if on { enabledSources.insert(source) } else { enabledSources.remove(source) } })) {
                            VStack(alignment: .leading) {
                                Text(source.label)
                                Text(source.methodDescription).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Picker("Resting session position", selection: $postureFilter) {
                        ForEach(PostureFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                statsSection
                quickLogSection
                insightsSection
                periodSection
            }
            .navigationTitle("Trends")
            .task(id: model.dataVersion) { reload() }
            .sheet(isPresented: $showEditor) {
                AnnotationEditorView(initialKind: editorKind) { new in
                    for a in new { try? model.database.saveAnnotation(a) }
                    model.dataChanged()
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    HStack {
                        Text(toast).font(.footnote)
                        if lastQuickLogged != nil {
                            Button("Undo") { undoQuickLog() }.font(.footnote.bold())
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func reload() {
        let resting = (try? model.database.fetchRestingMeasurements()) ?? []
        let imported = (try? model.database.fetchImported()) ?? []
        observations = resting.filter { $0.result.medianBPM != nil }.map { RHRObservation($0) } + imported.map { RHRObservation($0) }
        annotations = (try? model.database.fetchAnnotations()) ?? []
    }

    // MARK: Chart

    private var chart: some View {
        let start = startDay
        let startDate = start.startDate()
        let endDate = today.adding(days: 1).startDate()
        let visible = observations.filter { $0.day >= start && enabledSources.contains($0.source) }
            .filter { o in o.source != .controlled || postureFilter.posture == nil || o.posture == postureFilter.posture }
        let primary = daily(primarySource)
        let ma7 = TrendCalculator.movingAverage(primary, windowDays: 7, minimumCount: TrendCalculator.minimumFor7Day, from: start, through: today)
        let ma28 = TrendCalculator.movingAverage(primary, windowDays: 28, minimumCount: TrendCalculator.minimumFor28Day, from: start, through: today)
        let annotatedDays = Set(annotations.map(\.day)).filter { $0 >= start && $0 <= today }.sorted()
        let values = visible.map(\.bpm) + ma7.map(\.bpm)
        let lo = ((values.min() ?? 50) - 4).rounded(.down)
        let hi = ((values.max() ?? 70) + 4).rounded(.up)

        return Chart {
            ForEach(ma28, id: \.day) { p in
                LineMark(x: .value("Day", p.day.startDate().addingTimeInterval(12 * 3600)), y: .value("BPM", p.bpm),
                         series: .value("Series", "28-day average"))
                    .foregroundStyle(Color.blue.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
            ForEach(ma7, id: \.day) { p in
                LineMark(x: .value("Day", p.day.startDate().addingTimeInterval(12 * 3600)), y: .value("BPM", p.bpm),
                         series: .value("Series", "7-day average"))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(visible) { o in
                PointMark(x: .value("Day", o.day.startDate().addingTimeInterval(12 * 3600)), y: .value("BPM", o.bpm))
                    .foregroundStyle(color(for: o.source).opacity(o.isValid ? 1 : 0.3))
                    .symbol(symbol(for: o.source))
                    .symbolSize(o.isValid ? 40 : 25)
            }
            ForEach(annotatedDays, id: \.self) { d in
                PointMark(x: .value("Day", d.startDate().addingTimeInterval(12 * 3600)), y: .value("BPM", lo + 1))
                    .symbol(.triangle)
                    .symbolSize(30)
                    .foregroundStyle(Color.gray)
            }
            if let sel = selectedDate {
                RuleMark(x: .value("Selected", CalendarDay(sel).startDate().addingTimeInterval(12 * 3600)))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
        }
        .chartXScale(domain: startDate...endDate)
        .chartYScale(domain: max(20, lo)...max(hi, max(20, lo) + 10))
        .chartXSelection(value: $selectedDate)
        .overlay {
            if visible.isEmpty {
                Text("No resting heart rate data in this range yet.\nMeasure on the Resting tab or import WHOOP data in Settings.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(availableSources.filter { enabledSources.contains($0) }) { s in
                HStack(spacing: 4) {
                    Image(systemName: s == .controlled ? "circle.fill" : (s == .whoopOvernight ? "square.fill" : "diamond.fill"))
                        .foregroundStyle(color(for: s)).font(.caption2)
                    Text(s == .controlled ? "5-min" : (s == .whoopOvernight ? "WHOOP" : "Health")).font(.caption2)
                }
            }
            Text("— 7d avg").font(.caption2).foregroundStyle(.red)
            Text("- - 28d avg").font(.caption2).foregroundStyle(.blue)
            Image(systemName: "triangle.fill").font(.caption2).foregroundStyle(.gray)
            Text("notes").font(.caption2)
        }
        .foregroundStyle(.secondary)
    }

    private func color(for s: RHRSource) -> Color {
        switch s {
        case .controlled: return .red
        case .whoopOvernight: return .teal
        case .appleHealth: return .pink
        }
    }

    private func symbol(for s: RHRSource) -> BasicChartSymbolShape {
        switch s {
        case .controlled: return .circle
        case .whoopOvernight: return .square
        case .appleHealth: return .diamond
        }
    }

    @ViewBuilder private func selectionDetail(_ day: CalendarDay) -> some View {
        let obs = observations.filter { $0.day == day }
        let notes = annotations.filter { $0.day == day }
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.day(day)).font(.subheadline.bold())
            if obs.isEmpty && notes.isEmpty {
                Text("No data for this day.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(obs) { o in
                Text(describe(o)).font(.caption)
            }
            ForEach(notes) { a in
                Label(a.summary, systemImage: a.kind.systemImage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func describe(_ o: RHRObservation) -> String {
        var parts = ["\(Format.bpm(o.bpm, digits: 1)) BPM", o.source.label]
        if let p = o.posture { parts.append(p.label) }
        if !o.isValid { parts.append("flagged") }
        if !o.notes.isEmpty { parts.append(o.notes) }
        return parts.joined(separator: " · ")
    }

    // MARK: Statistics

    private var statsSection: some View {
        let s = TrendCalculator.summary(daily(primarySource), today: today)
        return Section {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    StatTile(title: "Latest", value: Format.bpm(s.latest?.bpm, digits: 1),
                             detail: s.latest.map { Format.day($0.day) })
                    StatTile(title: "7-day avg", value: Format.bpm(s.average7, digits: 1))
                    StatTile(title: "28-day avg", value: Format.bpm(s.average28, digits: 1))
                }
                GridRow {
                    StatTile(title: "30-day change", value: Format.signed(s.change30), detail: "7-day avg vs 30 days ago")
                    StatTile(title: "Trend", value: Format.signed(s.slopePerWeek, unit: "/wk"), detail: "linear fit, all data")
                    StatTile(title: "vs baseline", value: Format.signed(s.baselineDeviation),
                             detail: s.baselineZScore.map { String(format: "z = %.1f", $0) } ?? "28-day baseline")
                }
                GridRow {
                    StatTile(title: "Day-to-day SD", value: Format.bpm(s.consistencySD, digits: 1), detail: "last 28 days")
                    StatTile(title: "Days measured", value: "\(s.daysWithDataLast28)/28", detail: "missing days aren't filled")
                    StatTile(title: "Source", value: primarySource == .controlled ? "5-min" : "WHOOP", detail: postureFilter.rawValue)
                }
            }
        } header: {
            Text("Statistics")
        } footer: {
            Text("Values are BPM. A dash means there isn't enough data yet (7-day average needs 3 days, 28-day needs 7, trend needs 5 days over 2+ weeks). Sources are never mixed.")
        }
    }

    // MARK: Annotations

    private var quickLogSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(AnnotationKind.allCases) { kind in
                        Button {
                            quickLog(kind)
                        } label: {
                            Label(kind.label, systemImage: kind.systemImage).font(.footnote)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Button {
                editorKind = nil
                showEditor = true
            } label: {
                Label("Add Annotation", systemImage: "plus.circle")
            }
            let recent = annotations.filter { $0.day >= today.adding(days: -13) }.reversed()
            ForEach(Array(recent)) { a in
                HStack {
                    Image(systemName: a.kind.systemImage).foregroundStyle(.secondary)
                    Text(a.summary).font(.footnote)
                    Spacer()
                    Text(Format.day(a.day)).font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        try? model.database.deleteAnnotation(id: a.id)
                        model.dataChanged()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } header: {
            Text("Log behavior")
        } footer: {
            Text("Caffeine, alcohol, travel and illness log instantly for today. Sleep, exercise, stress and notes open a short form. Log sleep on the morning after.")
        }
    }

    private func quickLog(_ kind: AnnotationKind) {
        switch kind {
        case .caffeine, .alcohol, .travel, .illness:
            let a = Annotation(day: today, kind: kind, value: (kind == .caffeine || kind == .alcohol) ? 1 : nil)
            try? model.database.saveAnnotation(a)
            lastQuickLogged = a
            model.dataChanged()
            withAnimation { toast = "Logged \(kind.label.lowercased()) for today" }
            let id = a.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if lastQuickLogged?.id == id {
                    withAnimation { toast = nil }
                    lastQuickLogged = nil
                }
            }
        default:
            editorKind = kind
            showEditor = true
        }
    }

    private func undoQuickLog() {
        if let a = lastQuickLogged {
            try? model.database.deleteAnnotation(id: a.id)
            model.dataChanged()
        }
        lastQuickLogged = nil
        withAnimation { toast = nil }
    }

    // MARK: Insights

    private var insightsSection: some View {
        let d = daily(primarySource)
        let kinds: [AnnotationKind] = [.alcohol, .caffeine, .exercise, .stress, .travel, .illness]
        let comparisons = kinds.map { CorrelationAnalyzer.compare($0, annotations: annotations, daily: d) }
        let sleep = CorrelationAnalyzer.sleepAssociation(annotations: annotations, daily: d)
        return Section {
            ForEach(comparisons, id: \.kind) { c in
                InsightRow(title: "\(c.kind.label) → next-morning RHR", text: c.summary, strength: c.strength)
            }
            InsightRow(title: "Sleep duration → same-morning RHR", text: sleep.summary, strength: sleep.strength)
        } header: {
            Text("Patterns (observational)")
        } footer: {
            Text("Compares your logged behaviors with later resting heart rate. Days with nothing logged are ignored rather than counted as \"didn't happen\". These are associations, not proof of cause — sleep, illness, training load and timing all overlap. Stress counts as present at level 4–5.")
        }
    }

    private var periodSection: some View {
        let d = daily(primarySource)
        let weeks = Array(TrendCalculator.periods(d, by: .week).suffix(8).reversed())
        let months = Array(TrendCalculator.periods(d, by: .month).suffix(12).reversed())
        return Section("Weekly & monthly averages") {
            if weeks.isEmpty { Text("No data yet.").foregroundStyle(.secondary) }
            ForEach(weeks, id: \.start) { p in
                PeriodRow(label: "Week of \(Format.day(p.start))", summary: p)
            }
            ForEach(months, id: \.start) { p in
                PeriodRow(label: p.start.startDate().formatted(.dateTime.month(.wide).year()), summary: p)
            }
        }
    }
}

private struct InsightRow: View {
    let title: String
    let text: String
    let strength: EvidenceStrength

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(label).font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())
                    .foregroundStyle(color)
            }
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch strength {
        case .insufficient: return "Not enough data"
        case .weak: return "Weak evidence"
        case .moderate: return "Tentative pattern"
        }
    }

    private var color: Color {
        switch strength {
        case .insufficient: return .gray
        case .weak: return .orange
        case .moderate: return .blue
        }
    }
}

private struct PeriodRow: View {
    let label: String
    let summary: PeriodSummary

    var body: some View {
        HStack {
            Text(label).font(.footnote)
            Spacer()
            Text("\(Format.bpm(summary.mean, digits: 1)) BPM").font(.footnote.monospacedDigit())
            Text(summary.changeFromPrevious.map { Format.signed($0) } ?? "").font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            Text("\(summary.days)d").font(.caption2).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
        }
    }
}
