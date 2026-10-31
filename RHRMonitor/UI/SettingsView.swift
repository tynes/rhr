import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreBluetooth
import HeartRateKit
import HeartRateStore

/// Screen D — device, diagnostics, data export/import/deletion, privacy and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var counts: AppDatabase.Counts?
    @State private var share: ShareItem?
    @State private var exporting: ExportService.Kind?
    @State private var showImporter = false
    @State private var message: String?
    @State private var confirmDeleteAll = false
    @State private var confirmDeleteImported = false

    var body: some View {
        @Bindable var settings = model.settings
        NavigationStack {
            Form {
                deviceSection
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. In the WHOOP app, open your device settings and turn on **Heart Rate Broadcast**.")
                        Text("2. Wear the strap. Tap **Find device** and pick your WHOOP.")
                        Text("3. This app only *reads* the standard Bluetooth heart rate signal. It never pairs, writes to the strap, or changes its settings, so the WHOOP app keeps working normally.")
                    }
                    .font(.footnote)
                } header: {
                    Text("Setting up WHOOP")
                }

                Section("Diagnostics") {
                    NavigationLink("Bluetooth & sampling diagnostics") { DiagnosticsView() }
                }

                Section {
                    Stepper(value: $settings.restingMinimumCoverage, in: 0.5...1.0, step: 0.05) {
                        LabeledContent("Minimum data coverage", value: "\(Int((settings.restingMinimumCoverage * 100).rounded()))%")
                    }
                } header: {
                    Text("Resting measurement")
                } footer: {
                    Text("A measurement is flagged as unreliable if less than this share of the final 3 minutes has heart rate data.")
                }

                dataSection

                Section {
                    Toggle("Simulated heart rate", isOn: Binding(get: { settings.simulatedHeartRate },
                                                                 set: { model.setSimulation($0) }))
                    Toggle("Simulate dropouts", isOn: Binding(get: { model.mock.simulateDropouts },
                                                              set: { model.mock.simulateDropouts = $0 }))
                        .disabled(model.mock.isRunning)
                } header: {
                    Text("Testing")
                } footer: {
                    Text("Generates fake heart rate to try the app without a strap. Recordings made this way are labeled \"Simulated\". Turn this off to use your WHOOP.")
                }

                Section("Privacy") {
                    Text("All data stays on this iPhone in a local database protected by iOS Data Protection. There is no account, no server, no analytics and no tracking. Data leaves the phone only when you export and share it yourself.")
                        .font(.footnote)
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    Text("Open-source resting heart rate monitor. Uses the standard Bluetooth Heart Rate Service. Not affiliated with or endorsed by WHOOP. Not a medical device.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Thanks to the NOOP project (github.com/ryanbr/noop) for documenting that WHOOP 5.0/MG straps expose the standard heart rate profile.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task(id: model.dataVersion) { counts = try? model.database.counts() }
            .sheet(item: $share) { item in ShareSheet(items: item.urls) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                importWhoop(result)
            }
            .alert("Data", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog("Delete ALL data?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { deleteAll() }
            } message: {
                Text("This permanently removes every recording, sample, resting measurement, import and annotation from this iPhone. Export first if you want a copy.")
            }
            .confirmationDialog("Delete imported WHOOP values?", isPresented: $confirmDeleteImported, titleVisibility: .visible) {
                Button("Delete imported data", role: .destructive) {
                    try? model.database.deleteImported(source: .whoopOvernight)
                    model.dataChanged()
                }
            }
        }
    }

    // MARK: Device

    private var deviceSection: some View {
        let settings = model.settings
        return Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.ble.deviceName ?? "No device selected").font(.headline)
                    if let id = model.ble.deviceID {
                        Text(id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ConnectionStatusView(phase: model.ble.phase)
            }
            if let e = model.ble.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
            if model.ble.permissionDenied {
                Button("Open iOS Settings to allow Bluetooth") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            NavigationLink {
                DevicePickerView()
            } label: {
                Label("Find device", systemImage: "dot.radiowaves.left.and.right")
            }
            if model.ble.deviceID != nil {
                switch model.ble.phase {
                case .connected, .connecting, .reconnecting:
                    Button("Disconnect") { model.ble.disconnect() }
                default:
                    Button("Connect") { model.ble.reconnectSaved() }
                }
                Button("Forget device", role: .destructive) { model.ble.forget() }
            }
            Toggle("Reconnect automatically", isOn: Binding(get: { settings.autoReconnect },
                                                            set: { settings.autoReconnect = $0; model.ble.autoReconnect = $0 }))
        } header: {
            Text("Device")
        } footer: {
            Text("If the connection drops, the app keeps trying to reconnect, including in the background. Background collection is best-effort: iOS can pause or end the app, and gaps are recorded honestly.")
        }
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            if let c = counts {
                LabeledContent("Recordings", value: "\(c.sessions)")
                LabeledContent("Heart rate samples", value: "\(c.samples)")
                LabeledContent("Resting measurements", value: "\(c.restingMeasurements)")
                LabeledContent("Annotations", value: "\(c.annotations)")
                LabeledContent("Imported WHOOP days", value: "\(c.imported)")
            }
            ForEach(ExportService.Kind.allCases) { kind in
                Button {
                    runExport(kind)
                } label: {
                    HStack {
                        Label(kind.rawValue, systemImage: "square.and.arrow.up")
                        if exporting == kind { Spacer(); ProgressView() }
                    }
                }
                .disabled(exporting != nil)
            }
            Button {
                showImporter = true
            } label: {
                Label("Import WHOOP overnight RHR (CSV)", systemImage: "square.and.arrow.down")
            }
            if (counts?.imported ?? 0) > 0 {
                Button("Delete imported WHOOP data", role: .destructive) { confirmDeleteImported = true }
            }
            Button("Delete all data", role: .destructive) { confirmDeleteAll = true }
        } header: {
            Text("Data")
        } footer: {
            Text("Exports use ISO 8601 UTC timestamps with milliseconds, BPM for heart rate and milliseconds for RR intervals. Import expects physiological_cycles.csv from WHOOP's data export (WHOOP app › Settings › Data Export).")
        }
    }

    private func runExport(_ kind: ExportService.Kind) {
        exporting = kind
        Task { @MainActor in
            defer { exporting = nil }
            do {
                share = try await ExportService.export(kind, database: model.database)
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importWhoop(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try WhoopCSVImporter.parse(text)
            try model.database.upsertImported(parsed.values)
            model.dataChanged()
            let range = parsed.values.isEmpty ? "" : " from \(parsed.values.first!.day) to \(parsed.values.last!.day)"
            message = "Imported \(parsed.values.count) days of WHOOP overnight resting heart rate\(range) (dated by \(parsed.dateColumn)). Skipped \(parsed.skippedRows) rows without a value."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    private func deleteAll() {
        do {
            try model.deleteAllData()
            ExportService.cleanUp()
            message = "All data was deleted."
        } catch {
            message = "Delete failed: \(error.localizedDescription)"
        }
    }
}

/// Scans for heart rate devices and connects to the chosen one.
struct DevicePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if case .unavailable(let a) = model.ble.phase, a != .unknown {
                    Text(a.userMessage).foregroundStyle(.orange)
                }
                if model.ble.discovered.isEmpty {
                    HStack {
                        if model.ble.isScanning { ProgressView() }
                        Text(model.ble.isScanning ? "Looking for devices…" : "No devices found.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.ble.discovered) { d in
                    Button {
                        model.ble.connect(to: d.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: d.looksLikeWhoop ? "applewatch.side.right" : "heart.circle")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    if d.advertisesHeartRate { CapsuleTag(text: "Heart rate") }
                                    if d.looksLikeWhoop { CapsuleTag(text: "WHOOP") }
                                    if d.connectedToSystem { CapsuleTag(text: "Connected to iPhone") }
                                }
                            }
                            Spacer()
                            if let rssi = d.rssi { Text("\(rssi) dBm").font(.caption2).foregroundStyle(.secondary) }
                            if d.id == model.ble.deviceID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            } footer: {
                Text("Don't see your WHOOP? Make sure Heart Rate Broadcast is on in the WHOOP app, the strap is on your wrist, and it's charged. A strap that's already connected to this iPhone (for example by the WHOOP app) appears as \"Connected to iPhone\".")
            }
        }
        .navigationTitle("Find device")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.ble.isScanning ? "Stop" : "Scan") {
                    if model.ble.isScanning { model.ble.stopScan() } else { model.ble.startScan() }
                }
            }
        }
        .onAppear { model.ble.startScan() }
        .onDisappear { model.ble.stopScan() }
    }
}

private struct CapsuleTag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Bluetooth diagnostics and sampling statistics.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = model.ble.diagnostics
        List {
            Section("Bluetooth") {
                LabeledContent("Permission", value: authorizationText)
                LabeledContent("Radio", value: model.ble.machine.bluetooth.rawValue)
                LabeledContent("Connection", value: model.ble.phase.label)
                LabeledContent("Device", value: model.ble.deviceName ?? "—")
                LabeledContent("Connects / disconnects", value: "\(d.connects) / \(d.disconnects)")
            }
            Section {
                LabeledContent("Notifications received", value: "\(d.notifications)")
                LabeledContent("Mean interval", value: d.meanInterval.map { String(format: "%.2f s", $0) } ?? "—")
                LabeledContent("Longest interval (<30 s)", value: String(format: "%.1f s", d.maxInterval))
                LabeledContent("With RR intervals", value: percent(d.withRR, of: d.notifications))
                LabeledContent("Out-of-range BPM (dropped)", value: "\(d.implausible)")
                LabeledContent("No skin contact", value: "\(d.noContact)")
                LabeledContent("Malformed packets", value: "\(d.parseErrors)")
                LabeledContent("Last packet", value: d.lastPacketHex.isEmpty ? "—" : d.lastPacketHex)
            } header: {
                Text("Heart rate stream")
            } footer: {
                Text("Timestamps are when the iPhone received each notification. The strap decides how often it sends; RR intervals may be absent.")
            }
            Section("Storage") {
                LabeledContent("Recording", value: model.recorder.isRecording ? "Yes" : "No")
                LabeledContent("Samples this session", value: "\(model.recorder.recordedCount)")
                LabeledContent("Waiting to be written", value: "\(model.recorder.pendingCount)")
                LabeledContent("Last write error", value: model.recorder.lastWriteError ?? "None")
            }
            Section("Event log") {
                ForEach(model.ble.log.reversed()) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.date, format: .dateTime.hour().minute().second()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(entry.message).font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    private var authorizationText: String {
        switch model.ble.authorization {
        case .allowedAlways: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private func percent(_ n: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        return String(format: "%.0f%%", Double(n) / Double(total) * 100)
    }
}
