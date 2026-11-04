import Foundation
import Observation
import HeartRateKit
import HeartRateStore

/// Receives every heart rate reading, keeps the live chart buffer and persists samples while a
/// recording is active. Independent of any view: data keeps flowing when the chart isn't shown.
@Observable
final class RecordingCoordinator {
    /// Recent readings for the live chart (not necessarily recorded).
    private(set) var live = LiveBuffer()
    /// Last plausible reading.
    private(set) var latest: HeartRateMeasurement?
    private(set) var lastSampleAt: Date?
    /// Last raw reading, including implausible ones (e.g. 0 BPM when off-wrist).
    private(set) var lastRawBPM: Int?
    private(set) var lastRawAt: Date?
    private(set) var activeSession: RecordingSession?
    private(set) var recordedCount = 0
    private(set) var pendingCount = 0
    private(set) var lastWriteError: String?

    /// Set by the UI layer from the scene phase. In the background every sample is written
    /// immediately, because iOS may suspend or terminate the app without warning.
    var isInForeground = true

    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored private let engine: RecordingEngine
    @ObservationIgnored private var timer: Timer?
    /// Called once per second (and on each sample) so other controllers can advance.
    @ObservationIgnored var onTick: ((Date) -> Void)?

    init(database: AppDatabase) {
        self.database = database
        self.engine = RecordingEngine(sink: database)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick(now: Date())
        }
    }

    var isRecording: Bool { activeSession != nil }

    // MARK: - Ingest

    func handle(_ m: HeartRateMeasurement, at date: Date, sourceDevice: String) {
        lastRawBPM = m.bpm
        lastRawAt = date
        if m.isPlausible {
            latest = m
            lastSampleAt = date
            live.append(HeartRatePoint(timestamp: ISOTimestamp.truncated(date), bpm: m.bpm))
        }
        let result = engine.ingest(m, at: date, sourceDevice: sourceDevice)
        if case .recorded = result {
            recordedCount = engine.recordedCount
        }
        if !isInForeground { engine.flushIfDue(now: date, force: true) }
        syncEngineState()
        onTick?(date)
    }

    func tick(now: Date) {
        engine.flushIfDue(now: now)
        syncEngineState()
        onTick?(now)
    }

    func flushNow() {
        engine.flushIfDue(now: Date(), force: true)
        syncEngineState()
    }

    private func syncEngineState() {
        if pendingCount != engine.pending.count { pendingCount = engine.pending.count }
        if lastWriteError != engine.lastWriteError { lastWriteError = engine.lastWriteError }
    }

    // MARK: - Sessions

    @discardableResult
    func startRecording(kind: SessionKind, deviceID: String?, deviceName: String?, at date: Date = Date()) throws -> RecordingSession {
        if let current = activeSession { return current }
        let session = RecordingSession(startedAt: date, deviceIdentifier: deviceID, deviceName: deviceName, kind: kind)
        try database.insertSession(session)
        engine.start(sessionID: session.id, at: session.startedAt)
        activeSession = session
        recordedCount = 0
        logEvent("recording_started", kind.rawValue)
        return session
    }

    /// Stops the active recording and marks it completed (or interrupted).
    @discardableResult
    func stopRecording(at date: Date = Date(), status: SessionStatus = .completed) -> RecordingSession? {
        guard var session = activeSession else { return nil }
        logEvent("recording_stopped", "")
        engine.stop(at: date)
        syncEngineState()
        do {
            try database.finishSession(id: session.id, endedAt: date, status: status)
        } catch {
            lastWriteError = "Could not close the session: \(error.localizedDescription)"
        }
        session.endedAt = ISOTimestamp.truncated(date)
        session.status = status
        session.sampleCount = (try? database.fetchSession(id: session.id))?.sampleCount ?? engine.persistedCount
        activeSession = nil
        return session
    }

    /// Re-attaches to a session left open by a previous run (see `SessionRecovery`).
    func resume(_ session: RecordingSession, lastSampleAt: Date?) {
        engine.start(sessionID: session.id, at: session.startedAt, existingCount: session.sampleCount,
                     lastSampleAt: lastSampleAt)
        activeSession = session
        recordedCount = session.sampleCount
        if let samples = try? database.fetchSamples(sessionID: session.id) {
            live.replaceAll(with: samples.map(\.point))
        }
        logEvent("recording_resumed", "after app relaunch")
    }

    /// Records a connection event against the active session (and keeps unattached ones too).
    func logEvent(_ kind: String, _ detail: String) {
        try? database.insertEvent(ConnectionEvent(sessionID: activeSession?.id, timestamp: Date(), kind: kind, detail: detail))
    }

    /// Readings to plot since `date` (live buffer).
    func points(since date: Date) -> [HeartRatePoint] { live.since(date) }
}
