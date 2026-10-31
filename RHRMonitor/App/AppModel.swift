import Foundation
import Observation
import HeartRateKit
import HeartRateStore

/// Composition root: owns storage, Bluetooth, recording and the resting-HR workflow, and wires
/// the data pipeline WHOOP → CoreBluetooth → parser → RecordingCoordinator → SQLite / live UI.
///
/// Lives for the whole process (created by the app delegate), independent of SwiftUI views.
/// All mutation happens on the main thread (CoreBluetooth and timers deliver on main).
@Observable
final class AppModel {
    let settings: AppSettings
    let database: AppDatabase
    let ble: HeartRateBLEManager
    let recorder: RecordingCoordinator
    let resting: RestingSessionController
    let mock: MockHeartRateSource

    /// Set if the on-disk database could not be opened (data is then kept in memory only).
    private(set) var storageError: String?
    /// Bumped whenever stored sessions/measurements/annotations change, so screens reload.
    private(set) var dataVersion = 0

    init() {
        let settings = AppSettings()
        self.settings = settings

        var storageError: String?
        let database: AppDatabase
        do {
            database = try AppDatabase.openOnDisk(at: AppModel.databaseURL)
        } catch {
            storageError = "Storage unavailable (\(error.localizedDescription)). Readings are shown but NOT saved."
            // Falling back to memory keeps the live monitor usable; the banner makes the risk explicit.
            database = try! AppDatabase.inMemory()
        }
        self.database = database
        self.storageError = storageError

        let recorder = RecordingCoordinator(database: database)
        self.recorder = recorder
        self.resting = RestingSessionController(recorder: recorder, settings: settings)
        self.mock = MockHeartRateSource()
        self.ble = HeartRateBLEManager(savedDeviceID: settings.selectedDeviceID.flatMap(UUID.init(uuidString:)),
                                       savedDeviceName: settings.selectedDeviceName,
                                       autoReconnect: settings.autoReconnect)
        wire()
        recoverOpenSessions(now: Date())
        if settings.simulatedHeartRate { mock.start() }
    }

    static var databaseURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RHRMonitor", isDirectory: true).appendingPathComponent("rhr.sqlite")
    }

    private func wire() {
        ble.onMeasurement = { [weak self] m, date in
            guard let self, !self.mock.isRunning else { return }
            self.recorder.handle(m, at: date, sourceDevice: self.ble.deviceName ?? "Heart rate sensor")
        }
        ble.onConnectionEvent = { [weak self] kind, detail in
            self?.recorder.logEvent(kind, detail)
        }
        ble.onDeviceSelected = { [weak self] id, name in
            self?.settings.selectedDeviceID = id?.uuidString
            self?.settings.selectedDeviceName = name
        }
        mock.onMeasurement = { [weak self] m, date in
            self?.recorder.handle(m, at: date, sourceDevice: MockHeartRateGenerator.sourceName)
        }
        recorder.onTick = { [weak self] now in
            self?.resting.tick(now: now)
        }
        resting.onDataChanged = { [weak self] in
            self?.dataChanged()
        }
    }

    /// Handles sessions still marked "recording" from a previous run.
    private func recoverOpenSessions(now: Date) {
        guard let open = try? database.fetchOpenSessions() else { return }
        for session in open {
            let last: Date? = (try? database.lastSampleTime(sessionID: session.id)) ?? nil
            let decision = SessionRecovery.decide(session: session, lastSampleAt: last, now: now)
            if session.kind == .resting {
                let due = session.startedAt.addingTimeInterval(resting.protocolSettings.totalSeconds)
                if decision == .resume, now < due, !recorder.isRecording {
                    recorder.resume(session, lastSampleAt: last)
                    resting.resumeRunning(session)
                } else {
                    resting.finalizeOrphan(session)
                }
                continue
            }
            if decision == .resume, !recorder.isRecording {
                recorder.resume(session, lastSampleAt: last)
            } else {
                let end: Date
                if case .markInterrupted(let e) = decision { end = e } else { end = last ?? session.startedAt }
                try? database.finishSession(id: session.id, endedAt: end, status: .interrupted)
            }
        }
    }

    // MARK: - Derived state

    /// Live heart rate is being monitored (drives Keep Screen Awake).
    var isMonitoring: Bool {
        if recorder.isRecording || mock.isRunning { return true }
        switch ble.phase {
        case .connected, .connecting, .reconnecting: return true
        default: return false
        }
    }

    var sourceName: String {
        mock.isRunning ? "Simulated data" : (ble.deviceName ?? "No device")
    }

    // MARK: - Actions

    func startRecording() {
        do {
            try recorder.startRecording(kind: .freeform,
                                        deviceID: mock.isRunning ? MockHeartRateGenerator.sourceName : ble.deviceID?.uuidString,
                                        deviceName: mock.isRunning ? MockHeartRateGenerator.sourceName : ble.deviceName)
        } catch {
            storageError = "Could not start recording: \(error.localizedDescription)"
        }
        dataChanged()
    }

    func stopRecording() {
        recorder.stopRecording()
        dataChanged()
    }

    func setSimulation(_ on: Bool) {
        settings.simulatedHeartRate = on
        if on { mock.start() } else { mock.stop() }
    }

    func dataChanged() { dataVersion += 1 }

    func appDidEnterBackground() {
        recorder.isInForeground = false
        recorder.flushNow()
    }

    func appWillEnterForeground() {
        recorder.isInForeground = true
    }

    func prepareForTermination() {
        recorder.flushNow()
        // Leave the session marked "recording": if iOS relaunches us for Bluetooth soon, it resumes;
        // otherwise the next launch closes it as interrupted at the last stored sample.
    }

    func deleteAllData() throws {
        if resting.isRunning { resting.discard() }
        if recorder.isRecording { recorder.stopRecording(status: .interrupted) }
        try database.deleteAllData()
        dataChanged()
    }
}
