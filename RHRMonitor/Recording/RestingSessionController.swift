import Foundation
import Observation
import HeartRateKit
import HeartRateStore

/// Runs the standardized five-minute resting heart rate measurement.
///
/// The measurement is a recording session of kind `.resting`, so its samples are persisted
/// continuously like any other recording. When the five minutes are up the samples are read
/// back from the database and summarized with `RestingHRCalculator`.
@Observable
final class RestingSessionController {
    enum State: Equatable {
        case idle
        case running(sessionID: String, startedAt: Date, posture: Posture)
        case finished(RestingMeasurement)
    }

    private(set) var state: State = .idle
    private(set) var lastError: String?

    @ObservationIgnored private let recorder: RecordingCoordinator
    @ObservationIgnored private let settings: AppSettings
    /// Notifies the app that stored data changed.
    @ObservationIgnored var onDataChanged: (() -> Void)?

    init(recorder: RecordingCoordinator, settings: AppSettings) {
        self.recorder = recorder
        self.settings = settings
    }

    var protocolSettings: RestingHRProtocol {
        var p = RestingHRProtocol.standard
        p.minimumCoverage = settings.restingMinimumCoverage
        return p
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start(posture: Posture, deviceID: String?, deviceName: String?) {
        lastError = nil
        guard !recorder.isRecording else {
            lastError = "Stop the current recording before measuring resting heart rate."
            return
        }
        do {
            let session = try recorder.startRecording(kind: .resting, deviceID: deviceID, deviceName: deviceName)
            settings.setPendingPosture(posture.rawValue, sessionID: session.id)
            state = .running(sessionID: session.id, startedAt: session.startedAt, posture: posture)
        } catch {
            lastError = "Could not start: \(error.localizedDescription)"
        }
    }

    /// Advances the countdown; finishes automatically after five minutes.
    func tick(now: Date) {
        guard case .running(_, let start, _) = state else { return }
        if RestingHRCalculator.phase(start: start, now: now, settings: protocolSettings) == .finished {
            finish(endedAt: start.addingTimeInterval(protocolSettings.totalSeconds))
        }
    }

    /// Stops before five minutes. The result is saved but flagged as incomplete.
    func stopEarly() {
        guard case .running = state else { return }
        finish(endedAt: Date())
    }

    /// Stops and deletes the measurement entirely.
    func discard() {
        guard case .running(let id, _, _) = state else { return }
        recorder.stopRecording(status: .interrupted)
        try? recorder.database.deleteSession(id: id)
        settings.setPendingPosture(nil, sessionID: id)
        state = .idle
        onDataChanged?()
    }

    func dismissResult() {
        state = .idle
    }

    func updateNotes(_ notes: String) {
        guard case .finished(var m) = state else { return }
        m.notes = notes
        try? recorder.database.updateRestingNotes(id: m.id, notes: notes)
        state = .finished(m)
        onDataChanged?()
    }

    private func finish(endedAt: Date) {
        guard case .running(let id, let start, let posture) = state else { return }
        let stopped = recorder.stopRecording(at: endedAt)
        let samples = (try? recorder.database.fetchSamples(sessionID: id)) ?? []
        let result = RestingHRCalculator.analyze(samples: samples, start: start, end: stopped?.endedAt ?? endedAt,
                                                 settings: protocolSettings)
        save(sessionID: id, start: start, posture: posture, result: result)
    }

    private func save(sessionID: String, start: Date, posture: Posture, result: RestingHRResult) {
        let measurement = RestingMeasurement(sessionID: sessionID, startedAt: start, day: CalendarDay(start),
                                             timeZoneIdentifier: TimeZone.current.identifier, posture: posture,
                                             settings: protocolSettings, result: result)
        do {
            try recorder.database.saveRestingMeasurement(measurement)
        } catch {
            lastError = "Could not save the measurement: \(error.localizedDescription)"
        }
        settings.setPendingPosture(nil, sessionID: sessionID)
        state = .finished(measurement)
        onDataChanged?()
    }

    // MARK: - Recovery after relaunch

    /// Resumes the countdown for a resting session that was open when the app relaunched.
    func resumeRunning(_ session: RecordingSession) {
        let posture = settings.pendingPosture(sessionID: session.id).flatMap(Posture.init(rawValue:)) ?? .sitting
        state = .running(sessionID: session.id, startedAt: session.startedAt, posture: posture)
    }

    /// Finalizes a resting session whose five minutes elapsed while the app wasn't running.
    func finalizeOrphan(_ session: RecordingSession) {
        let p = protocolSettings
        let end = session.startedAt.addingTimeInterval(p.totalSeconds)
        let samples = (try? recorder.database.fetchSamples(sessionID: session.id)) ?? []
        let result = RestingHRCalculator.analyze(samples: samples, start: session.startedAt, end: end, settings: p)
        try? recorder.database.finishSession(id: session.id, endedAt: end, status: result.isValid ? .completed : .interrupted)
        let posture = settings.pendingPosture(sessionID: session.id).flatMap(Posture.init(rawValue:)) ?? .sitting
        let measurement = RestingMeasurement(sessionID: session.id, startedAt: session.startedAt,
                                             day: CalendarDay(session.startedAt), timeZoneIdentifier: TimeZone.current.identifier,
                                             posture: posture, settings: p, result: result,
                                             notes: "Finished while the app was not running.")
        try? recorder.database.saveRestingMeasurement(measurement)
        settings.setPendingPosture(nil, sessionID: session.id)
    }
}
