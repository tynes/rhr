import SwiftUI
import HeartRateKit
import HeartRateStore

/// Recording session history.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [RecordingSession] = []

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform.path.ecg",
                                           description: Text("Start a recording on the Live tab."))
                }
                ForEach(sessions) { s in
                    NavigationLink {
                        SessionDetailView(sessionID: s.id)
                    } label: {
                        SessionRow(session: s, isActive: s.id == model.recorder.activeSession?.id)
                    }
                }
            }
            .navigationTitle("History")
            .task(id: model.dataVersion) { reload() }
            .refreshable { reload() }
        }
    }

    private func reload() {
        sessions = (try? model.database.fetchSessions()) ?? []
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Format.dateTime.string(from: session.startedAt)).font(.subheadline.weight(.semibold))
                Spacer()
                StatusBadge(status: isActive ? .recording : session.status)
            }
            HStack(spacing: 10) {
                Label(session.kind == .resting ? "Resting" : "Recording",
                      systemImage: session.kind == .resting ? "figure.mind.and.body" : "waveform.path.ecg")
                Text(isActive ? "in progress" : Format.duration(session.duration()))
                Text("\(session.sampleCount) samples")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .recording: return "Recording"
        case .completed: return "Completed"
        case .interrupted: return "Interrupted"
        }
    }

    private var color: Color {
        switch status {
        case .recording: return .red
        case .completed: return .green
        case .interrupted: return .orange
        }
    }
}

/// One session: chart, statistics, gaps, connection events, notes, export, delete.
struct SessionDetailView: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var session: RecordingSession?
    @State private var samples: [HeartRateSample] = []
    @State private var events: [ConnectionEvent] = []
    @State private var resting: RestingMeasurement?
    @State private var notes = ""
    @State private var loading = true
    @State private var share: ShareItem?
    @State private var confirmDelete = false
    @State private var scrollPosition = Date()

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if let session {
                content(session)
            } else {
                Text("This session no longer exists.")
            }
        }
        .navigationTitle(session.map { Format.dateTime.string(from: $0.startedAt) } ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) { await load() }
        .sheet(item: $share, onDismiss: ExportService.cleanUp) { item in ShareSheet(items: item.urls) }
        .confirmationDialog("Delete this session and its samples?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? model.database.deleteSession(id: sessionID)
                model.dataChanged()
                dismiss()
            }
        }
    }

    @ViewBuilder private func content(_ s: RecordingSession) -> some View {
        let points = samples.map(\.point)
        let first = s.startedAt
        let last = max(s.endedAt ?? samples.last?.timestamp ?? first, first.addingTimeInterval(10))
        let series = ChartDownsampler.series(from: points, maxPoints: 800)
        let bpms = samples.map { Double($0.bpm) }
        let gaps = GapDetector.gaps(in: samples.map(\.timestamp))
        let isActive = s.id == model.recorder.activeSession?.id

        Section {
            HeartRateChart(series: series, xDomain: first...last, scrollPosition: $scrollPosition)
                .frame(height: 220)
            if series.isDownsampled {
                Text("Long session: each point is the average of a short time bucket (press and hold for its range).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        Section("Summary") {
            LabeledContent("Status") { StatusBadge(status: isActive ? .recording : s.status) }
            LabeledContent("Type", value: s.kind == .resting ? "Resting measurement" : "Recording")
            LabeledContent("Duration", value: isActive ? "in progress" : Format.duration(s.duration()))
            LabeledContent("Samples", value: "\(samples.count)")
            LabeledContent("Average", value: "\(Format.bpm(Stats.mean(bpms), digits: 1)) BPM")
            LabeledContent("Median", value: "\(Format.bpm(Stats.median(bpms), digits: 1)) BPM")
            LabeledContent("Min / Max", value: "\(samples.map(\.bpm).min().map(String.init) ?? "—") / \(samples.map(\.bpm).max().map(String.init) ?? "—") BPM")
            LabeledContent("With RR intervals", value: "\(samples.filter { !$0.rrIntervalsMs.isEmpty }.count)")
            LabeledContent("Device", value: s.deviceName ?? "—")
        }
        if let resting {
            Section("Resting result") { RestingResultView(measurement: resting) }
        }
        Section {
            if gaps.isEmpty {
                Text("No gaps longer than \(Int(GapDetector.defaultThreshold)) s.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Gaps", value: "\(gaps.count), total \(Format.duration(gaps.reduce(0) { $0 + $1.duration }))")
                ForEach(Array(gaps.sorted { $0.duration > $1.duration }.prefix(10).enumerated()), id: \.offset) { _, g in
                    HStack {
                        Text(g.start, format: .dateTime.hour().minute().second())
                        Text("→")
                        Text(g.end, format: .dateTime.hour().minute().second())
                        Spacer()
                        Text(Format.duration(g.duration)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text("Data gaps")
        } footer: {
            Text("Periods with no samples (disconnected, out of range, or iOS paused the app). Nothing is filled in.")
        }
        if !events.isEmpty {
            Section("Connection events") {
                ForEach(events, id: \.id) { e in
                    HStack(alignment: .top) {
                        Text(e.timestamp, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit())
                        Text(e.kind.replacingOccurrences(of: "_", with: " ")).font(.caption.weight(.medium))
                        if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        Section("Notes") {
            TextField("Notes", text: $notes, axis: .vertical)
            Button("Save notes") {
                try? model.database.updateSessionNotes(id: s.id, notes: notes)
                model.dataChanged()
            }
            .disabled(notes == s.notes)
        }
        Section {
            Button {
                share = ExportService.shareSessionSamples(s, samples: samples)
            } label: {
                Label("Export samples (CSV)", systemImage: "square.and.arrow.up")
            }
            if !isActive {
                Button("Delete session", role: .destructive) { confirmDelete = true }
            }
        }
    }

    private func load() async {
        let db = model.database
        session = try? db.fetchSession(id: sessionID)
        samples = (try? await db.fetchSamplesAsync(sessionID: sessionID)) ?? []
        events = (try? db.fetchEvents(sessionID: sessionID)) ?? []
        resting = try? db.fetchRestingMeasurement(sessionID: sessionID)
        notes = session?.notes ?? ""
        loading = false
    }
}
