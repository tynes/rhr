import Foundation
import SwiftUI
import UIKit
import HeartRateKit
import HeartRateStore

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Writes export files to a private temporary folder for the share sheet.
/// Data only leaves the device if the user picks a destination in the share sheet. The files
/// are encrypted while the phone is locked and deleted when the share sheet closes, at the next
/// launch, and by "Delete all data", so copies of health data don't pile up in the app's storage.
enum ExportService {
    enum Kind: String, CaseIterable, Identifiable {
        case samples = "Heart rate samples (CSV)"
        case sessions = "Recording sessions (CSV)"
        case resting = "Resting HR measurements (CSV)"
        case annotations = "Annotations (CSV)"
        case json = "Everything (JSON)"
        var id: String { rawValue }
    }

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    static func write(_ text: String, name: String) throws -> URL {
        try write(Data(text.utf8), name: name)
    }

    static func write(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Names are built by this file from fixed prefixes, UUID prefixes and timestamps; never let
        // one escape the export folder.
        let url = folder.appendingPathComponent((name as NSString).lastPathComponent)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static var stamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    static func export(_ kind: Kind, database: AppDatabase) async throws -> ShareItem {
        let bundle = try await database.exportBundle()
        let url: URL
        switch kind {
        case .samples: url = try write(CSVExporter.samplesCSV(bundle.samples), name: "rhr-samples-\(stamp).csv")
        case .sessions: url = try write(CSVExporter.sessionsCSV(bundle.sessions), name: "rhr-sessions-\(stamp).csv")
        case .resting: url = try write(CSVExporter.restingCSV(bundle.restingMeasurements), name: "rhr-resting-\(stamp).csv")
        case .annotations: url = try write(CSVExporter.annotationsCSV(bundle.annotations), name: "rhr-annotations-\(stamp).csv")
        case .json: url = try write(try bundle.jsonData(), name: "rhr-all-\(stamp).json")
        }
        return ShareItem(urls: [url])
    }

    static func shareSessionSamples(_ session: RecordingSession, samples: [HeartRateSample]) -> ShareItem? {
        let name = "rhr-session-\(session.id.prefix(8))-\(stamp).csv"
        guard let url = try? write(CSVExporter.samplesCSV(samples), name: name) else { return nil }
        return ShareItem(urls: [url])
    }

    /// Deletes every export file. Called when the share sheet closes and at launch.
    static func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// UIKit share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
