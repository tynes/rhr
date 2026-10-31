import XCTest
@testable import HeartRateKit

final class MemorySink: SampleSink {
    var stored: [String: [HeartRateSample]] = [:]
    var failNext = 0
    var writeCalls = 0
    struct Failure: Error {}

    func persist(_ samples: [HeartRateSample], sessionID: String) throws {
        writeCalls += 1
        if failNext > 0 { failNext -= 1; throw Failure() }
        var existing = stored[sessionID, default: []]
        for s in samples where !existing.contains(where: { $0.timestampMs == s.timestampMs }) { existing.append(s) }
        stored[sessionID] = existing
    }
}

final class RecordingEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func m(_ bpm: Int) -> HeartRateMeasurement { HeartRateMeasurement(bpm: bpm, sensorContact: .detected) }

    func testNotRecordingDoesNotPersist() {
        let sink = MemorySink()
        let e = RecordingEngine(sink: sink)
        XCTAssertEqual(e.ingest(m(60), at: t0, sourceDevice: "W"), .notRecording)
        XCTAssertTrue(sink.stored.isEmpty)
    }

    func testBatchesBySizeAndTime() {
        let sink = MemorySink()
        let e = RecordingEngine(sink: sink, configuration: .init(maxBatchSize: 5, maxFlushInterval: 2))
        e.start(sessionID: "s", at: t0)
        // Notifications every 0.3 s: the 2-second bound triggers before 5 samples accumulate? 0.3*5 = 1.5 s, so size wins.
        for i in 0..<4 { e.ingest(m(60 + i), at: t0.addingTimeInterval(Double(i) * 0.3), sourceDevice: "W") }
        XCTAssertEqual(sink.stored["s"]?.count ?? 0, 0)
        e.ingest(m(64), at: t0.addingTimeInterval(1.2), sourceDevice: "W")
        XCTAssertEqual(sink.stored["s"]?.count, 5)

        // Time bound: one sample then a tick 2 s later flushes it.
        e.ingest(m(65), at: t0.addingTimeInterval(3), sourceDevice: "W")
        XCTAssertFalse(e.flushIfDue(now: t0.addingTimeInterval(4)))
        XCTAssertTrue(e.flushIfDue(now: t0.addingTimeInterval(5)))
        XCTAssertEqual(sink.stored["s"]?.count, 6)
        XCTAssertEqual(e.persistedCount, 6)
    }

    func testRejectsImplausibleAndDuplicates() {
        let sink = MemorySink()
        let e = RecordingEngine(sink: sink)
        e.start(sessionID: "s", at: t0)
        XCTAssertEqual(e.ingest(m(0), at: t0, sourceDevice: "W"), .rejectedImplausible)
        XCTAssertEqual(e.ingest(m(300), at: t0, sourceDevice: "W"), .rejectedImplausible)
        guard case .recorded = e.ingest(m(60), at: t0, sourceDevice: "W") else { return XCTFail() }
        XCTAssertEqual(e.ingest(m(61), at: t0.addingTimeInterval(0.0004), sourceDevice: "W"), .duplicate)
        e.stop(at: t0.addingTimeInterval(1))
        XCTAssertEqual(sink.stored["s"]?.map(\.bpm), [60])
    }

    func testWriteFailureRetainsAndRetries() {
        let sink = MemorySink()
        let e = RecordingEngine(sink: sink, configuration: .init(maxBatchSize: 2, maxFlushInterval: 2))
        e.start(sessionID: "s", at: t0)
        sink.failNext = 1
        e.ingest(m(60), at: t0, sourceDevice: "W")
        e.ingest(m(61), at: t0.addingTimeInterval(1), sourceDevice: "W")
        XCTAssertNotNil(e.lastWriteError)
        XCTAssertEqual(e.pending.count, 2)
        e.ingest(m(62), at: t0.addingTimeInterval(2), sourceDevice: "W")
        XCTAssertNil(e.lastWriteError)
        XCTAssertEqual(e.pending.count, 0)
        XCTAssertEqual(sink.stored["s"]?.map(\.bpm), [60, 61, 62])
    }

    func testStopFlushesEverything() {
        let sink = MemorySink()
        let e = RecordingEngine(sink: sink)
        e.start(sessionID: "s", at: t0)
        e.ingest(m(60), at: t0, sourceDevice: "W")
        XCTAssertTrue(e.stop(at: t0.addingTimeInterval(0.5)))
        XCTAssertEqual(sink.stored["s"]?.count, 1)
        XCTAssertEqual(e.state, .idle)
        XCTAssertEqual(e.ingest(m(60), at: t0.addingTimeInterval(1), sourceDevice: "W"), .notRecording)
    }

    func testFailedFlushOnStopIsRetriedLater() {
        let sink = MemorySink()
        let e = RecordingEngine(sink: sink)
        e.start(sessionID: "s", at: t0)
        e.ingest(m(60), at: t0, sourceDevice: "W")
        sink.failNext = 1
        XCTAssertFalse(e.stop(at: t0))
        XCTAssertTrue(e.flushIfDue(now: t0.addingTimeInterval(1), force: true))
        XCTAssertEqual(sink.stored["s"]?.count, 1)
    }

    func testRecordedSampleCarriesFields() {
        let sink = MemorySink()
        let e = RecordingEngine(sink: sink)
        e.start(sessionID: "s", at: t0)
        let r = e.ingest(HeartRateMeasurement(bpm: 58, sensorContact: .detected, rrIntervalsMs: [1000]), at: t0, sourceDevice: "WHOOP MG")
        guard case .recorded(let s) = r else { return XCTFail() }
        XCTAssertEqual(s.sessionID, "s")
        XCTAssertEqual(s.rrIntervalsMs, [1000])
        XCTAssertEqual(s.sourceDevice, "WHOOP MG")
        XCTAssertEqual(s.timestamp, t0)
    }

    func testSessionRecoveryDecision() {
        let s = RecordingSession(id: "a", startedAt: t0)
        XCTAssertEqual(SessionRecovery.decide(session: s, lastSampleAt: t0.addingTimeInterval(600), now: t0.addingTimeInterval(900)), .resume)
        let last = t0.addingTimeInterval(600)
        XCTAssertEqual(SessionRecovery.decide(session: s, lastSampleAt: last, now: t0.addingTimeInterval(600 + 3600)),
                       .markInterrupted(endedAt: last))
        XCTAssertEqual(SessionRecovery.decide(session: s, lastSampleAt: nil, now: t0.addingTimeInterval(7200)),
                       .markInterrupted(endedAt: t0))
    }
}

final class ConnectionMachineTests: XCTestCase {
    func testHappyPath() {
        var c = ConnectionMachine()
        XCTAssertEqual(c.phase, .unavailable(.unknown))
        c.handle(.bluetooth(.poweredOn))
        XCTAssertEqual(c.phase, .disconnected)
        XCTAssertEqual(c.handle(.startScan), [.startScan])
        XCTAssertEqual(c.phase, .scanning)
        XCTAssertEqual(c.handle(.connect), [.stopScan, .connectPeripheral])
        XCTAssertEqual(c.phase, .connecting)
        XCTAssertEqual(c.handle(.didConnect), [.discoverServices])
        c.handle(.subscribed)
        XCTAssertEqual(c.phase, .connected)
    }

    func testUnexpectedDisconnectReconnects() {
        var c = ConnectionMachine()
        c.handle(.bluetooth(.poweredOn)); c.handle(.connect); c.handle(.didConnect); c.handle(.subscribed)
        XCTAssertEqual(c.handle(.didDisconnect), [.connectPeripheral])
        XCTAssertEqual(c.phase, .reconnecting)
        XCTAssertEqual(c.handle(.didConnect), [.discoverServices])
        XCTAssertEqual(c.phase, .reconnecting, "stay 'reconnecting' until notifications resume")
        c.handle(.subscribed)
        XCTAssertEqual(c.phase, .connected)
    }

    func testUserDisconnectDoesNotReconnect() {
        var c = ConnectionMachine()
        c.handle(.bluetooth(.poweredOn)); c.handle(.connect); c.handle(.didConnect); c.handle(.subscribed)
        XCTAssertEqual(c.handle(.userDisconnect), [.cancelPeripheral])
        XCTAssertEqual(c.handle(.didDisconnect), [])
        XCTAssertEqual(c.phase, .disconnected)
    }

    func testBluetoothOffThenOnReconnects() {
        var c = ConnectionMachine()
        c.handle(.bluetooth(.poweredOn)); c.handle(.connect); c.handle(.didConnect); c.handle(.subscribed)
        XCTAssertEqual(c.handle(.bluetooth(.poweredOff)), [])
        XCTAssertEqual(c.phase, .unavailable(.poweredOff))
        XCTAssertEqual(c.handle(.didDisconnect), [])
        XCTAssertEqual(c.handle(.bluetooth(.poweredOn)), [.connectPeripheral])
        XCTAssertEqual(c.phase, .reconnecting)
    }

    func testFailedConnectBacksOff() {
        var c = ConnectionMachine()
        c.handle(.bluetooth(.poweredOn)); c.handle(.connect)
        XCTAssertEqual(c.handle(.didFailToConnect), [.scheduleReconnect(after: 2)])
        XCTAssertEqual(c.handle(.didFailToConnect), [.scheduleReconnect(after: 4)])
        for _ in 0..<10 { c.handle(.didFailToConnect) }
        XCTAssertEqual(c.handle(.didFailToConnect), [.scheduleReconnect(after: 30)])
    }

    func testServiceMissingStops() {
        var c = ConnectionMachine()
        c.handle(.bluetooth(.poweredOn)); c.handle(.connect); c.handle(.didConnect)
        XCTAssertEqual(c.handle(.serviceMissing), [.cancelPeripheral])
        XCTAssertEqual(c.handle(.didDisconnect), [])
        XCTAssertEqual(c.phase, .disconnected)
    }

    func testUnauthorized() {
        var c = ConnectionMachine()
        c.handle(.bluetooth(.unauthorized))
        XCTAssertEqual(c.handle(.startScan), [])
        XCTAssertEqual(c.phase, .unavailable(.unauthorized))
    }

    func testFreshness() {
        let t = Date()
        XCTAssertEqual(ReadingFreshness.evaluate(lastSampleAt: nil, now: t), .none)
        XCTAssertEqual(ReadingFreshness.evaluate(lastSampleAt: t.addingTimeInterval(-3), now: t), .live)
        XCTAssertEqual(ReadingFreshness.evaluate(lastSampleAt: t.addingTimeInterval(-12), now: t), .stale(age: 12))
    }

    func testKeepAwakeArbiter() {
        XCTAssertTrue(KeepAwakeArbiter.sceneWantsAwake(userEnabled: true, monitoringActive: true, sceneActive: true, monitorVisible: true))
        XCTAssertFalse(KeepAwakeArbiter.sceneWantsAwake(userEnabled: false, monitoringActive: true, sceneActive: true, monitorVisible: true))
        XCTAssertFalse(KeepAwakeArbiter.sceneWantsAwake(userEnabled: true, monitoringActive: false, sceneActive: true, monitorVisible: true))
        XCTAssertFalse(KeepAwakeArbiter.sceneWantsAwake(userEnabled: true, monitoringActive: true, sceneActive: false, monitorVisible: true))
        XCTAssertFalse(KeepAwakeArbiter.sceneWantsAwake(userEnabled: true, monitoringActive: true, sceneActive: true, monitorVisible: false))

        var a = KeepAwakeArbiter()
        XCTAssertTrue(a.set("scene1", wantsAwake: true))
        XCTAssertTrue(a.set("scene2", wantsAwake: true))
        XCTAssertTrue(a.set("scene1", wantsAwake: false), "scene2 still needs the screen awake")
        XCTAssertFalse(a.set("scene2", wantsAwake: false))
    }
}
