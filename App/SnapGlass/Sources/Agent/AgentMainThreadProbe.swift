import Foundation

/// Independent main-thread stall probe.
///
/// A detached task posts a timestamped block to the main queue every 50 ms. When
/// the main thread finally runs it, the elapsed time is the stall. The probe
/// never reads UI state, never holds a lock on the main thread, and never blocks
/// it; the samples live in main-actor memory and are reduced only at the end.
@MainActor
final class AgentMainThreadProbe {
    /// How often the probe pings the main queue.
    static let pingInterval: Duration = .milliseconds(50)

    private var samples: [Int] = []
    private var pinger: Task<Void, Never>?
    private(set) var isRunning = false

    /// Starts pinging; repeated calls are ignored.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        pinger = Task.detached(priority: .high) { [weak self] in
            while !Task.isCancelled {
                let sent = ContinuousClock.now
                await MainActor.run {
                    self?.record(sentAt: sent)
                }
                if Task.isCancelled { break }
                try? await Task.sleep(for: Self.pingInterval)
            }
        }
    }

    /// Stops pinging and returns the reduced samples.
    ///
    /// - Returns: The largest observed stall in milliseconds and the sample count.
    func stop() -> (maxStallMs: Int, sampleCount: Int) {
        pinger?.cancel()
        pinger = nil
        isRunning = false
        return (samples.max() ?? 0, samples.count)
    }

    /// The current maximum without stopping the probe.
    var maxStallMs: Int { samples.max() ?? 0 }

    /// The number of samples recorded so far.
    var sampleCount: Int { samples.count }

    private func record(sentAt: ContinuousClock.Instant) {
        samples.append(AgentHUDMetrics.milliseconds(from: sentAt, to: .now))
    }
}
