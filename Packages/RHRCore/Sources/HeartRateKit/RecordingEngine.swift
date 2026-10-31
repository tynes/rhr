import Foundation

/// Where recorded samples are written. Implemented by the SQLite store and by test doubles.
public protocol SampleSink: AnyObject {
    /// Persists a batch of samples for one session atomically. Must ignore samples that are
    /// already stored (same session and timestamp) so a retried batch never duplicates rows.
    func persist(_ samples: [HeartRateSample], sessionID: String) throws
}

public enum IngestResult: Equatable, Sendable {
    case recorded(HeartRateSample)
    /// Valid reading, but no recording is active.
    case notRecording
    /// BPM outside the plausible range; never stored.
    case rejectedImplausible
    /// Same millisecond as the previous sample; dropped.
    case duplicate
}

/// Buffers samples during a recording and writes them to a `SampleSink` in small batches.
///
/// Pure logic (no timers): callers feed it samples and call `flushIfDue(now:)` periodically.
/// Batches flush after `maxBatchSize` samples or `maxFlushInterval` seconds, whichever comes
/// first, so at most a couple of seconds of data is ever held only in memory. Failed writes stay
/// queued and are retried on the next flush.
public final class RecordingEngine {
    public struct Configuration: Equatable, Sendable {
        public var maxBatchSize: Int
        public var maxFlushInterval: TimeInterval
        /// Upper bound on samples held in memory while writes keep failing.
        public var maxPendingSamples: Int

        public init(maxBatchSize: Int = 15, maxFlushInterval: TimeInterval = 2, maxPendingSamples: Int = 50_000) {
            self.maxBatchSize = maxBatchSize
            self.maxFlushInterval = maxFlushInterval
            self.maxPendingSamples = maxPendingSamples
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case recording(sessionID: String, startedAt: Date)

        public var sessionID: String? {
            if case .recording(let id, _) = self { return id }
            return nil
        }
    }

    public private(set) var state: State = .idle
    public private(set) var pending: [HeartRateSample] = []
    /// Samples successfully written in the current (or last) session.
    public private(set) var persistedCount = 0
    /// Samples accepted into the current session (persisted + pending).
    public private(set) var recordedCount = 0
    public private(set) var lastWriteError: String?
    public private(set) var droppedForOverflow = 0
    public private(set) var lastSampleAt: Date?
    private var oldestPendingAt: Date?
    private var lastTimestampMs: Int64?

    public let configuration: Configuration
    private let sink: SampleSink

    public init(sink: SampleSink, configuration: Configuration = Configuration()) {
        self.sink = sink
        self.configuration = configuration
    }

    public var isRecording: Bool { state.sessionID != nil }

    /// Begins (or resumes) recording into `sessionID`. `existingCount` seeds counters on resume.
    public func start(sessionID: String, at date: Date, existingCount: Int = 0, lastSampleAt: Date? = nil) {
        state = .recording(sessionID: sessionID, startedAt: ISOTimestamp.truncated(date))
        persistedCount = existingCount
        recordedCount = existingCount
        self.lastSampleAt = lastSampleAt
        lastTimestampMs = lastSampleAt.map(ISOTimestamp.milliseconds)
        lastWriteError = nil
    }

    /// Accepts one reading. Records it only while a session is active.
    @discardableResult
    public func ingest(_ m: HeartRateMeasurement, at timestamp: Date, sourceDevice: String) -> IngestResult {
        guard m.isPlausible else { return .rejectedImplausible }
        guard case .recording(let sessionID, _) = state else { return .notRecording }
        let sample = HeartRateSample(sessionID: sessionID, timestamp: timestamp, bpm: m.bpm,
                                     rrIntervalsMs: m.rrIntervalsMs, sensorContact: m.sensorContact,
                                     sourceDevice: sourceDevice)
        if let last = lastTimestampMs, sample.timestampMs == last { return .duplicate }
        lastTimestampMs = sample.timestampMs
        lastSampleAt = sample.timestamp
        if pending.count >= configuration.maxPendingSamples {
            pending.removeFirst()
            droppedForOverflow += 1
        }
        pending.append(sample)
        recordedCount += 1
        if oldestPendingAt == nil { oldestPendingAt = timestamp }
        flushIfDue(now: timestamp)
        return .recorded(sample)
    }

    /// Writes pending samples if the batch is full, the oldest one is too old, or `force` is set.
    /// Returns true when nothing remains pending.
    @discardableResult
    public func flushIfDue(now: Date, force: Bool = false) -> Bool {
        guard !pending.isEmpty else { return true }
        let tooOld = oldestPendingAt.map { now.timeIntervalSince($0) >= configuration.maxFlushInterval } ?? false
        guard force || tooOld || pending.count >= configuration.maxBatchSize else { return false }
        return flush()
    }

    private func flush() -> Bool {
        // Group by session in case a stop/start happened while writes were failing.
        var ok = true
        var remaining: [HeartRateSample] = []
        var order: [String] = []
        var groups: [String: [HeartRateSample]] = [:]
        for s in pending {
            if groups[s.sessionID] == nil { order.append(s.sessionID) }
            groups[s.sessionID, default: []].append(s)
        }
        for id in order {
            let batch = groups[id] ?? []
            do {
                try sink.persist(batch, sessionID: id)
                if id == state.sessionID || state.sessionID == nil { persistedCount += batch.count }
            } catch {
                ok = false
                lastWriteError = String(describing: error)
                remaining += batch
            }
        }
        pending = remaining
        oldestPendingAt = remaining.first?.timestamp
        if ok { lastWriteError = nil }
        return pending.isEmpty
    }

    /// Stops recording and flushes. Returns true if every sample was written.
    @discardableResult
    public func stop(at date: Date) -> Bool {
        let flushed = flushIfDue(now: date, force: true)
        state = .idle
        lastTimestampMs = nil
        return flushed
    }
}

/// What to do with a session that was still marked `recording` when the app launched.
public enum SessionRecovery {
    public enum Decision: Equatable, Sendable {
        /// Continue appending to the same session; the outage shows up as a gap.
        case resume
        /// Close it as interrupted, ending at the last stored sample (or its start).
        case markInterrupted(endedAt: Date)
    }

    /// Sessions whose last activity is within `resumeWindow` are resumed (e.g. iOS relaunched the
    /// app in the background for a Bluetooth event); older ones are closed as interrupted.
    public static func decide(session: RecordingSession, lastSampleAt: Date?, now: Date,
                              resumeWindow: TimeInterval = 30 * 60) -> Decision {
        let lastActivity = max(lastSampleAt ?? session.startedAt, session.startedAt)
        if now.timeIntervalSince(lastActivity) <= resumeWindow { return .resume }
        return .markInterrupted(endedAt: lastActivity)
    }
}
