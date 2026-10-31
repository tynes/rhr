import SwiftUI
import HeartRateKit
import HeartRateStore

/// Screen B — standardized five-minute resting heart rate measurement.
struct RestingHRView: View {
    @Environment(AppModel.self) private var model
    @Environment(KeepAwakeController.self) private var keepAwake

    @State private var posture: Posture = .sitting
    @State private var history: [RestingMeasurement] = []
    @State private var notes = ""
    @State private var confirmDiscard = false
    @State private var scrollPosition = Date()

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            List {
                switch model.resting.state {
                case .idle:
                    idleSection
                case .running(_, let startedAt, let posture):
                    runningSection(startedAt: startedAt, posture: posture)
                case .finished(let m):
                    Section("Result") {
                        RestingResultView(measurement: m)
                        TextField("Notes (optional)", text: $notes, axis: .vertical)
                            .onSubmit { model.resting.updateNotes(notes) }
                        Button("Save notes") { model.resting.updateNotes(notes) }
                            .disabled(notes == m.notes)
                        Button("Done") { model.resting.dismissResult() }
                            .bold()
                    }
                    .onAppear { notes = m.notes }
                }

                Section {
                    KeepAwakeToggle(isOn: $settings.keepScreenAwake, isActive: keepAwake.isActive,
                                    monitoring: model.isMonitoring)
                }

                Section("History") {
                    if history.isEmpty {
                        Text("No resting measurements yet.").foregroundStyle(.secondary)
                    }
                    ForEach(history) { m in
                        NavigationLink {
                            ScrollView { RestingResultView(measurement: m).padding() }
                                .navigationTitle(Format.dateTime.string(from: m.startedAt))
                        } label: {
                            RestingHistoryRow(measurement: m)
                        }
                    }
                }
            }
            .navigationTitle("Resting HR")
            .task(id: model.dataVersion) { reload() }
            .confirmationDialog("Discard this measurement?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { model.resting.discard() }
            }
        }
    }

    private func reload() {
        history = (try? model.database.fetchRestingMeasurements()) ?? []
    }

    private var canStart: Bool {
        ReadingFreshness.evaluate(lastSampleAt: model.recorder.lastSampleAt, now: Date()) == .live
            && !model.recorder.isRecording
    }

    @ViewBuilder private var idleSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Five-minute resting measurement").font(.headline)
                Text("Sit or lie still and breathe normally. The first 2 minutes let your heart rate settle; your result is the median of the last 3 minutes. Measure at the same time and in the same position each day (ideally soon after waking) so results are comparable.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("This is separate from WHOOP's overnight resting heart rate, which WHOOP calculates during sleep with its own method.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Position", selection: $posture) {
                ForEach(Posture.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if let e = model.resting.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            Button {
                model.resting.start(posture: posture,
                                    deviceID: model.mock.isRunning ? MockHeartRateGenerator.sourceName : model.ble.deviceID?.uuidString,
                                    deviceName: model.mock.isRunning ? MockHeartRateGenerator.sourceName : model.ble.deviceName)
            } label: {
                Label("Measure Resting HR", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            if !canStart {
                Text(model.recorder.isRecording ? "Stop the current recording on the Live tab first."
                                                : "Waiting for a live heart rate reading.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func runningSection(startedAt: Date, posture: Posture) -> some View {
        let p = model.resting.protocolSettings
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let phase = RestingHRCalculator.phase(start: startedAt, now: context.date, settings: p)
                let elapsed = min(p.totalSeconds, context.date.timeIntervalSince(startedAt))
                VStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: elapsed / p.totalSeconds)
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(phaseTitle(phase)).font(.headline)
                            Text(Format.duration(remaining(phase))).font(.largeTitle.monospacedDigit().bold())
                            Text(posture.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 190, height: 190)
                    .frame(maxWidth: .infinity)
                    CurrentBPMView(bpm: model.recorder.latest?.bpm, lastSampleAt: model.recorder.lastSampleAt,
                                   rawBPM: model.recorder.lastRawBPM, rawAt: model.recorder.lastRawAt, size: 56)
                    let points = model.recorder.points(since: startedAt)
                    HeartRateChart(series: ChartDownsampler.series(from: points, maxPoints: 600),
                                   xDomain: startedAt...startedAt.addingTimeInterval(p.totalSeconds),
                                   scrollPosition: $scrollPosition,
                                   marker: (startedAt.addingTimeInterval(p.settleSeconds), "Measuring"))
                        .frame(height: 160)
                }
            }
        }
        Section {
            Button("Stop early (save, flagged incomplete)") { model.resting.stopEarly() }
            Button("Discard measurement", role: .destructive) { confirmDiscard = true }
        } footer: {
            Text("Keep the app open, or leave the phone locked nearby — recording continues in the background on a best-effort basis. Gaps are flagged in the result.")
        }
    }

    private func phaseTitle(_ phase: RestingHRCalculator.Phase) -> String {
        switch phase {
        case .settling: return "Settling"
        case .measuring: return "Measuring"
        case .finished: return "Finishing…"
        }
    }

    private func remaining(_ phase: RestingHRCalculator.Phase) -> TimeInterval {
        switch phase {
        case .settling(let r), .measuring(let r): return r
        case .finished: return 0
        }
    }
}

struct RestingHistoryRow: View {
    let measurement: RestingMeasurement

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dateTime.string(from: measurement.startedAt)).font(.subheadline)
                Text(measurement.posture.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if measurement.result.isValid {
                Text("\(Format.bpm(measurement.result.medianBPM)) BPM").font(.headline).monospacedDigit()
            } else {
                Label("Flagged", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Statistics for one resting measurement, with validity flags.
struct RestingResultView: View {
    let measurement: RestingMeasurement

    var body: some View {
        let r = measurement.result
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.bpm(r.medianBPM)).font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                Text("BPM median").foregroundStyle(.secondary)
                Spacer()
                if r.isValid {
                    Label("Valid", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.subheadline)
                } else {
                    Label("Not reliable", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    StatTile(title: "Mean", value: Format.bpm(r.meanBPM, digits: 1))
                    StatTile(title: "Min / Max", value: "\(r.minBPM.map(String.init) ?? "—") / \(r.maxBPM.map(String.init) ?? "—")")
                }
                GridRow {
                    StatTile(title: "Std. dev.", value: Format.bpm(r.sdBPM, digits: 1))
                    StatTile(title: "Coverage", value: String(format: "%.0f%%", r.coverage * 100),
                             detail: "minimum \(Int(measurement.settings.minimumCoverage * 100))%")
                }
                GridRow {
                    StatTile(title: "Samples", value: "\(r.sampleCount)", detail: "in last 3 min")
                    StatTile(title: "Longest gap", value: Format.duration(r.largestGapSeconds))
                }
            }
            ForEach(r.flags, id: \.self) { flag in
                Label(flag.message, systemImage: flag.invalidates ? "xmark.octagon.fill" : "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(flag.invalidates ? Color.red : Color.orange)
            }
            Text("\(measurement.posture.label) · \(Format.dateTime.string(from: measurement.startedAt)) · \(measurement.timeZoneIdentifier)")
                .font(.caption).foregroundStyle(.secondary)
            if !measurement.notes.isEmpty {
                Text(measurement.notes).font(.footnote)
            }
        }
    }
}
