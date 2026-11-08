/// Errors raised by invalid recording lifecycle transitions.
public enum RecordingSessionStateError: Error, Equatable, Sendable {
    /// A recording has already started or is no longer idle.
    case alreadyStarted
    /// The recording has not entered its starting phase.
    case notStarting
    /// The recording is not currently active.
    case notRecording
    /// The recording has not entered its stopping phase.
    case notStopping
    /// The writer is not currently saving.
    case notSaving
}

/// Pure state machine for a single recording and its writer finalization.
public struct RecordingSessionState: Equatable, Sendable {
    /// Observable phases of the recording lifecycle.
    public enum Phase: String, Equatable, Sendable {
        /// No recording has started.
        case idle
        /// The capture stream and writer are being started.
        case starting
        /// The stream is actively recording.
        case recording
        /// The stream is stopping and draining pending samples.
        case stopping
        /// The finalized media file is being published.
        case saving
        /// The output file was successfully published.
        case finished
        /// The recording ended with a failure.
        case failed
    }

    /// Current phase of the recording lifecycle.
    public private(set) var phase: Phase = .idle

    /// Creates an idle recording state.
    public init() {}

    /// Begins the start transition; duplicate starts are rejected.
    public mutating func beginStart() throws {
        guard phase == .idle else { throw RecordingSessionStateError.alreadyStarted }
        phase = .starting
    }

    /// Marks the capture stream and writer as active.
    public mutating func recordingDidStart() throws {
        guard phase == .starting else { throw RecordingSessionStateError.notStarting }
        phase = .recording
    }

    /// Begins the stop transition; duplicate or premature stops are rejected.
    public mutating func beginStop() throws {
        guard phase == .recording else { throw RecordingSessionStateError.notRecording }
        phase = .stopping
    }

    /// Marks the stream as drained and the writer as finalizing.
    public mutating func beginSaving() throws {
        guard phase == .stopping else { throw RecordingSessionStateError.notStopping }
        phase = .saving
    }

    /// Marks the session complete after successful file publication.
    public mutating func finish() throws {
        guard phase == .saving else { throw RecordingSessionStateError.notSaving }
        phase = .finished
    }

    /// Moves any unfinished session into its terminal failure phase.
    public mutating func fail() {
        guard phase != .finished else { return }
        phase = .failed
    }
}
