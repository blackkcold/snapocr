import Foundation
import os

/// Independent main-thread stall probe.
///
/// A dispatch timer on its own serial queue keeps a timestamped block queued on
/// the main queue. When the main thread is blocked, the queued block cannot run,
/// so the elapsed time it measures is the stall. The arming path never runs on
/// the main thread, so a block is pending even while the main thread is blocked.
/// The probe never reads UI state; its only main-queue work is an append.
@MainActor
final class AgentMainThreadProbe {
    /// How often the probe queues a ping.
    static let pingInterval: DispatchTimeInterval = .milliseconds(50)
    /// How many pings may be queued at once.
    ///
    /// Two keep a ping in flight when one main-queue turn is slow, while bounding
    /// the work that drains after a stall.
    static let maximumInFlightPings = 2

    private struct State: Sendable {
        var samples: [Int] = []
        var inFlightPings = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(
        label: "com.snapglass.agent.main-thread-probe",
        qos: .userInitiated
    )
    private var timer: DispatchSourceTimer?

    /// Whether pings are currently queued.
    var isRunning: Bool { timer != nil }

    /// Starts pinging; repeated calls are ignored.
    func start() {
        guard timer == nil else { return }
        // Capture the sendable lock and cap so the handler never touches `self`.
        let state = self.state
        let cap = Self.maximumInFlightPings
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.pingInterval,
            leeway: .milliseconds(5)
        )
        // The handler runs on the probe queue, never on the main actor.
        timer.setEventHandler { @Sendable in
            let armedAt = DispatchTime.now()
            let didArm = state.withLock { state -> Bool in
                guard state.inFlightPings < cap else { return false }
                state.inFlightPings += 1
                return true
            }
            guard didArm else { return }
            DispatchQueue.main.async {
                let measured = DispatchTime.now().uptimeNanoseconds - armedAt.uptimeNanoseconds
                let latencyMs = Int(measured / 1_000_000)
                state.withLock { state in
                    state.inFlightPings -= 1
                    state.samples.append(latencyMs)
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// Stops pinging and returns the reduced samples.
    ///
    /// - Returns: The largest observed stall in milliseconds and the sample count.
    func stop() -> (maxStallMs: Int, sampleCount: Int) {
        timer?.cancel()
        timer = nil
        return state.withLock { ($0.samples.max() ?? 0, $0.samples.count) }
    }

    /// The current maximum without stopping the probe.
    var maxStallMs: Int {
        state.withLock { $0.samples.max() ?? 0 }
    }

    /// The number of samples recorded so far.
    var sampleCount: Int {
        state.withLock { $0.samples.count }
    }
}
