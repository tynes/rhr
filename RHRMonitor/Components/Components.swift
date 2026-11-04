import SwiftUI
import UIKit
import HeartRateKit

/// Colored dot + connection phase label.
struct ConnectionStatusView: View {
    let phase: ConnectionPhase
    var simulated = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(simulated ? "Simulated" : phase.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(simulated ? "Simulated" : phase.label)")
    }

    private var color: Color {
        if simulated { return .purple }
        switch phase {
        case .connected: return .green
        case .connecting, .scanning: return .yellow
        case .reconnecting: return .orange
        case .disconnected, .unavailable: return .gray
        }
    }
}

/// Large BPM readout that makes clear whether the value is live, stale or missing.
struct CurrentBPMView: View {
    let bpm: Int?
    let lastSampleAt: Date?
    /// Recent implausible raw value (e.g. 0 when the strap is off the wrist).
    var rawBPM: Int?
    var rawAt: Date?
    var size: CGFloat = 96

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = ReadingFreshness.evaluate(lastSampleAt: lastSampleAt, now: context.date)
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(freshness == .live ? Color.red : Color.gray)
                        .symbolEffect(.pulse, isActive: freshness == .live)
                    Text(bpm.map(String.init) ?? "--")
                        .font(.system(size: size, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(freshness == .live ? Color.primary : Color.secondary)
                        .strikethrough(isStale(freshness), color: .secondary)
                        .contentTransition(.numericText())
                    Text("BPM")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(caption(freshness, now: context.date))
                    .font(.footnote)
                    .foregroundStyle(freshness == .live ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func isStale(_ f: ReadingFreshness) -> Bool {
        if case .stale = f { return true }
        return false
    }

    private func caption(_ f: ReadingFreshness, now: Date) -> String {
        if let raw = rawBPM, let rawAt, now.timeIntervalSince(rawAt) < 5, !HeartRateMeasurementParser.plausibleRange.contains(raw) {
            return "Strap is reporting \(raw) BPM — is it on your wrist?"
        }
        switch f {
        case .none: return "Waiting for heart rate…"
        case .live: return "Live reading"
        case .stale(let age): return "No new reading for \(Format.duration(age)) — last value shown is not current"
        }
    }
}

/// Keep Screen Awake toggle with status and explanation.
struct KeepAwakeToggle: View {
    @Binding var isOn: Bool
    let isActive: Bool
    let monitoring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn.animation()) {
                Label("Keep Screen Awake", systemImage: isActive ? "sun.max.fill" : "sun.max")
                    .font(.headline)
            }
            if isOn {
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isActive ? Color.orange : Color.secondary)
                Text("Auto-lock is paused while this screen is open and heart rate is being monitored. You can still lock the phone manually, and Bluetooth can still disconnect or iOS can still interrupt the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        if isActive { return "Screen will stay on" }
        return monitoring ? "Will apply while this screen is in the foreground" : "Will apply once heart rate monitoring starts"
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Banner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var color: Color = .orange

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

enum Format {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func bpm(_ v: Double?, digits: Int = 0) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", v)
    }

    static func signed(_ v: Double?, digits: Int = 1, unit: String = "") -> String {
        guard let v else { return "—" }
        return String(format: "%+.\(digits)f", v) + unit
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    static func day(_ d: CalendarDay) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d.startDate())
    }
}
