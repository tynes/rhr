import Foundation
import Observation
import HeartRateKit

/// Synthetic 1 Hz heart rate stream for testing the UI and storage without a strap.
/// Every sample is labeled "Simulated" in storage and the UI shows a banner while it runs.
@Observable
final class MockHeartRateSource {
    private(set) var isRunning = false
    /// Insert a 15-second dropout every 2 minutes to exercise gap handling.
    var simulateDropouts = true

    @ObservationIgnored var onMeasurement: ((HeartRateMeasurement, Date) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var generator = MockHeartRateGenerator()
    @ObservationIgnored private var startedAt = Date()

    func start() {
        guard !isRunning else { return }
        generator = MockHeartRateGenerator(seed: UInt64(Date().timeIntervalSince1970),
                                           dropoutEvery: simulateDropouts ? 120 : nil)
        startedAt = Date()
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.emit()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func emit() {
        let now = Date()
        if let m = generator.measurement(elapsed: now.timeIntervalSince(startedAt)) {
            onMeasurement?(m, now)
        }
    }
}
