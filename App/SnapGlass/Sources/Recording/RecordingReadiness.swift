import CaptureCore
import Foundation

/// Conservative, uncalibrated bounds for recording readiness and UI settlement.
///
/// These values only decide when to keep waiting versus showing a bounded,
/// honest state. They are not claims about how long a normal save takes: a save
/// that legitimately runs longer keeps running and reports its real result.
enum RecordingReadiness {
    /// How long to wait for the video writer to accept its first frame.
    static let firstVideoFrameDeadline: Duration = .seconds(5)
    /// How long to wait for the first real captured audio sample.
    static let firstAudioSampleDeadline: Duration = .seconds(15)
    /// How long the main actor has to confirm that it presented the promoted
    /// recording state after real audio arrived.
    ///
    /// This is not a media deadline: it exists because readiness success cancels
    /// the first-sample deadline. Without a second bound, a main thread that stops
    /// responding after readiness leaves capture running with nobody able to stop
    /// it. The supervisor stops and saves the session itself at this deadline.
    static let firstAudioPresentationDeadline: Duration = .seconds(8)
    /// How long the main actor has to confirm that it presented the promoted
    /// screen-recording state after the writer accepted its first frame.
    ///
    /// The screen promotion is a plain state update, but it still runs on the main
    /// actor. A stalled actor must not leave the capture running unbounded.
    static let firstScreenPresentationDeadline: Duration = .seconds(8)
    /// How long a recording main actor may go without proving it is still alive.
    ///
    /// Once a recording is live, a periodic heartbeat is the only fact that
    /// distinguishes "recording with a visible HUD" from "recording behind a
    /// frozen interface". The supervisor stops and saves the session at this
    /// deadline instead of capturing forever with no way for the user to stop it.
    /// Screen sessions renew it from the monitoring loop; audio sessions renew it
    /// from the progress consumer.
    static let recordingLivenessDeadline: Duration = .seconds(10)
    /// How long a platform start call may run before the UI shows a bounded result.
    ///
    /// This covers the pipeline factory and the platform start call only. It never
    /// bounds an authorized system permission prompt, which resolves before start.
    static let platformStartDeadline: Duration = .seconds(30)
    /// How long a user-facing cancel or quit waits before showing a bounded result.
    static let uiSettleDeadline: Duration = .seconds(10)
    /// How long an already-authorized source enumeration may take.
    ///
    /// This bound is applied only when capture access is already granted. While the
    /// system authorization prompt is still possible, enumeration is not bounded:
    /// the user may legitimately take minutes to answer, so expiring there would
    /// be a false timeout. That wait stays cancellable instead.
    static let sourceEnumerationDeadline: Duration = .seconds(8)
    /// Polling interval for the writer-accepted-frame observation.
    static let observationInterval: Duration = .milliseconds(100)

    /// Runs `operation` but stops waiting after `timeout`.
    ///
    /// The operation runs in its own task and the timeout in another; a one-shot
    /// gate resumes the continuation exactly once. On timeout the operation task
    /// is cancelled and `nil` is returned. This deliberately avoids a structured
    /// task group, whose scope would wait for a non-cooperative child on exit.
    ///
    /// - Parameters:
    ///   - timeout: The maximum time to wait for the operation.
    ///   - operation: Sendable work that produces the value.
    /// - Returns: The operation's value, or `nil` when the timeout won.
    static func awaitBounded<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let clock = ContinuousClock()
        return await withCheckedContinuation { continuation in
            let gate = ReadinessRaceGate(continuation)
            let work = Task {
                let value = await operation()
                gate.resolve(value)
            }
            let timer = Task {
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                gate.resolve(nil)
                work.cancel()
            }
            gate.attach(timer: timer)
        }
    }

    /// Polls `probe` until it is true or the deadline passes.
    ///
    /// Each probe is itself bounded by the remaining deadline, so a locked actor
    /// cannot make the caller wait past `timeout`.
    ///
    /// - Parameters:
    ///   - timeout: Total time budget for the observation.
    ///   - interval: Delay between probes.
    ///   - probe: A sendable query that reports whether readiness was reached.
    /// - Returns: `true` when a probe reported readiness; `false` on timeout.
    static func waitUntil(
        _ timeout: Duration,
        interval: Duration = observationInterval,
        _ probe: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            guard let ready = await awaitBounded(remaining, operation: probe) else { return false }
            if ready { return true }
            let left = clock.now.duration(to: deadline)
            guard left > .zero else { return false }
            do {
                try await clock.sleep(for: min(interval, left))
            } catch {
                return false
            }
        }
    }
}

/// One-shot continuation gate for a bounded race.
private final class ReadinessRaceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func attach(timer: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
    }

    func resolve(_ value: T?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}

/// Errors that describe a bounded readiness or settlement result.
enum RecordingReadinessError: LocalizedError, Equatable {
    /// No video frame reached the writer before the readiness deadline.
    case noVideoFrames
    /// No real audio sample arrived before the readiness deadline.
    case noAudioSamples
    /// The user cancelled while capture was still starting.
    case cancelledWhileStarting
    /// A user-facing wait ended before the underlying operation returned.
    case uiWaitTimedOut
    /// The platform start call did not return before the startup deadline.
    case startTimedOut
    /// The UI already settled; the late start no longer owns the session.
    case supersededStart
    /// The source list did not load before the bounded enumeration deadline.
    case sourceListTimedOut
    /// Frames reached the capture callback, but the video writer never accepted one.
    case videoWriterWaitTimedOut
    /// The video writer reported a failure before accepting the first frame.
    case videoWriterFailed

    var errorDescription: String? {
        switch self {
        case .noVideoFrames:
            AppLocalization.string("No video frames were received. The recording was stopped.")
        case .noAudioSamples:
            AppLocalization.string("No audio samples were received. The recording was stopped.")
        case .cancelledWhileStarting:
            AppLocalization.string("The recording was cancelled before it started.")
        case .uiWaitTimedOut:
            AppLocalization.string("The recording is still being saved in the background.")
        case .startTimedOut:
            AppLocalization.string(
                "The recording took too long to start. It is being stopped in the background."
            )
        case .supersededStart:
            AppLocalization.string("The recording start no longer applies.")
        case .sourceListTimedOut:
            AppLocalization.string("Loading the recording sources took too long. Try again.")
        case .videoWriterWaitTimedOut:
            AppLocalization.string(
                "Frames arrived, but the video writer did not accept the first frame in time. The recording was stopped."
            )
        case .videoWriterFailed:
            AppLocalization.string("The video writer failed before the recording started.")
        }
    }
}
