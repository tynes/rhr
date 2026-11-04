import SwiftUI
import HeartRateKit

enum LiveRange: String, CaseIterable, Identifiable {
    case oneMinute = "1m", fiveMinutes = "5m", fifteenMinutes = "15m", session = "Session"
    var id: String { rawValue }
    var seconds: TimeInterval? {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .session: return nil
        }
    }
}

/// Screen A — live monitor.
struct LiveMonitorView: View {
    @Environment(AppModel.self) private var model
    @Environment(KeepAwakeController.self) private var keepAwake
    @Binding var tab: AppTab

    @State private var range: LiveRange = .fiveMinutes
    @State private var following = true
    @State private var scrollPosition = Date()
    @State private var dimmed = false
    @State private var confirmStop = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    banners
                    CurrentBPMView(bpm: model.recorder.latest?.bpm, lastSampleAt: model.recorder.lastSampleAt,
                                   rawBPM: model.recorder.lastRawBPM, rawAt: model.recorder.lastRawAt)
                        .padding(.vertical, 4)
                    chartCard
                    recordingCard
                    Card {
                        KeepAwakeToggle(isOn: $settings.keepScreenAwake, isActive: keepAwake.isActive,
                                        monitoring: model.isMonitoring)
                        if keepAwake.isActive {
                            Button {
                                withAnimation { dimmed = true }
                            } label: {
                                Label("Dim display", systemImage: "moon.fill")
                            }
                            .buttonStyle(.bordered)
                            Text("Dimming covers the screen with a dark overlay to reduce glare and power use. It does not make collection more reliable. Tap anywhere to restore.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    recordButton
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Live")
            .navigationBarTitleDisplayMode(.inline)
        }
        .overlay {
            if dimmed && keepAwake.isActive {
                DimOverlay(bpm: model.recorder.latest?.bpm, lastSampleAt: model.recorder.lastSampleAt,
                           recording: model.recorder.isRecording) {
                    withAnimation { dimmed = false }
                }
            }
        }
        .confirmationDialog("Stop recording?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop Recording", role: .destructive) { model.stopRecording() }
        } message: {
            Text("\(model.recorder.recordedCount) samples have been saved.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sourceName).font(.headline)
                if model.mock.isRunning {
                    Text("Testing mode — not real heart rate").font(.caption).foregroundStyle(.purple)
                }
            }
            Spacer()
            ConnectionStatusView(phase: model.ble.phase, simulated: model.mock.isRunning)
        }
    }

    @ViewBuilder private var banners: some View {
        if let e = model.storageError { Banner(text: e, color: .red) }
        if let e = model.recorder.lastWriteError {
            Banner(text: "Saving failed (\(model.recorder.pendingCount) samples waiting, will retry): \(e)", color: .red)
        }
        if case .unavailable(let a) = model.ble.phase, a != .unknown, !model.mock.isRunning {
            Banner(text: a.userMessage, systemImage: "antenna.radiowaves.left.and.right.slash")
        }
        if model.ble.permissionDenied && !model.mock.isRunning {
            Banner(text: "Bluetooth access is off for this app. Enable it in iOS Settings › Privacy & Security › Bluetooth.",
                   systemImage: "lock.fill")
        }
        if let e = model.ble.lastError, !model.mock.isRunning { Banner(text: e) }
        if model.ble.deviceID == nil && !model.mock.isRunning {
            Card {
                Text("Connect your WHOOP").font(.headline)
                Text("Turn on Heart Rate Broadcast in the WHOOP app (Device settings), then pick your strap here.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    tab = .settings
                    model.ble.startScan()
                } label: {
                    Label("Find device", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.ble.phase == .disconnected && !model.mock.isRunning {
            Button {
                model.ble.reconnectSaved()
            } label: {
                Label("Reconnect to \(model.ble.deviceName ?? "device")", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var chartCard: some View {
        Card {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(LiveRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Button {
                    following.toggle()
                    scrollPosition = Date().addingTimeInterval(-(range.seconds ?? 300))
                } label: {
                    Image(systemName: following ? "pause.fill" : "play.fill")
                        .frame(width: 22)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(following ? "Pause auto-scroll to inspect" : "Resume live auto-scroll")
            }
            if following {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    liveChart(now: context.date)
                }
                .frame(height: 220)
            } else {
                inspectChart.frame(height: 220)
                Text("Paused: drag to scroll, press and hold to inspect values.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Shaded bands are gaps with no data. Lines are never drawn across them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func rangeStart(now: Date) -> Date {
        if let s = range.seconds { return now.addingTimeInterval(-s) }
        return model.recorder.activeSession?.startedAt ?? model.recorder.live.points.first?.timestamp ?? now.addingTimeInterval(-300)
    }

    private func liveChart(now: Date) -> some View {
        let start = rangeStart(now: now)
        let end = max(now, start.addingTimeInterval(10))
        let series = ChartDownsampler.series(from: model.recorder.points(since: start), maxPoints: 600)
        return HeartRateChart(series: series, xDomain: start...end, scrollPosition: $scrollPosition)
    }

    private var inspectChart: some View {
        let points = model.recorder.live.points
        let first = points.first?.timestamp ?? Date().addingTimeInterval(-300)
        let last = max(points.last?.timestamp ?? Date(), first.addingTimeInterval(10))
        let series = ChartDownsampler.series(from: points, maxPoints: 1500)
        return HeartRateChart(series: series, xDomain: first...last,
                              visibleSeconds: range.seconds ?? max(60, last.timeIntervalSince(first)),
                              scrollPosition: $scrollPosition)
    }

    private var recordingCard: some View {
        Card {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let status = recordingStatus(now: context.date)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(status.color).frame(width: 10, height: 10)
                        Text(status.text).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let s = model.recorder.activeSession {
                            Text(Format.clock(context.date.timeIntervalSince(s.startedAt)))
                                .font(.title3.monospacedDigit().weight(.semibold))
                        }
                    }
                    HStack {
                        LabeledContent("Samples", value: "\(model.recorder.recordedCount)")
                        Divider()
                        LabeledContent("Last sample") {
                            if let t = model.recorder.lastSampleAt {
                                Text(t, format: .dateTime.hour().minute().second())
                            } else {
                                Text("—")
                            }
                        }
                    }
                    .font(.footnote)
                    if model.recorder.isRecording && model.recorder.activeSession?.kind == .resting {
                        Text("A resting measurement is in progress (Resting tab).").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func recordingStatus(now: Date) -> (text: String, color: Color) {
        guard model.recorder.isRecording else { return ("Not recording", .gray) }
        let fresh = ReadingFreshness.evaluate(lastSampleAt: model.recorder.lastSampleAt, now: now) == .live
        if fresh { return ("Recording · receiving samples", .red) }
        if model.mock.isRunning { return ("Recording · waiting for samples (simulated gap)", .orange) }
        switch model.ble.phase {
        case .connected: return ("Recording · waiting for samples", .orange)
        case .reconnecting, .connecting: return ("Recording · disconnected, reconnecting — gap is being recorded", .orange)
        default: return ("Recording · no device connected — gap is being recorded", .orange)
        }
    }

    private var recordButton: some View {
        Button {
            if model.recorder.isRecording {
                if model.recorder.activeSession?.kind == .resting {
                    tab = .resting
                } else {
                    confirmStop = true
                }
            } else {
                model.startRecording()
            }
        } label: {
            Label(model.recorder.isRecording ? "Stop Recording" : "Start Recording",
                  systemImage: model.recorder.isRecording ? "stop.fill" : "record.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.recorder.isRecording ? .gray : .red)
        .disabled(!model.recorder.isRecording && !model.isMonitoring)
        .overlay(alignment: .bottom) {
            if !model.recorder.isRecording && !model.isMonitoring {
                Text("Connect a device to record").font(.caption2).foregroundStyle(.secondary).offset(y: 18)
            }
        }
        .padding(.bottom, 20)
    }
}

/// Near-black overlay for long sessions; still shows the current BPM. Tap to dismiss.
private struct DimOverlay: View {
    let bpm: Int?
    let lastSampleAt: Date?
    let recording: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 8) {
                CurrentBPMView(bpm: bpm, lastSampleAt: lastSampleAt, size: 64)
                    .opacity(0.45)
                if recording {
                    Label("Recording", systemImage: "record.circle").font(.caption).foregroundStyle(.red.opacity(0.5))
                }
                Text("Tap to restore").font(.caption2).foregroundStyle(.gray.opacity(0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .statusBarHidden()
    }
}
