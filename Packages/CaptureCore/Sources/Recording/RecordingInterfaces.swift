import Foundation

/// Supplies microphone authorization state and requests access when needed.
public protocol MicrophoneAuthorizing {
    /// Returns the current authorization state without prompting the user.
    ///
    /// - Returns: The current microphone authorization state.
    func currentState() -> MicrophoneAuthorizationState

    /// Requests microphone access, prompting the user when the state is undetermined.
    ///
    /// - Returns: The authorization state after the request completes.
    func requestAccess() async -> MicrophoneAuthorizationState
}

/// Receives ordered PCM blocks and commits durable checkpoints.
public protocol AudioCheckpointSink {
    /// Appends one owned PCM block to the current checkpoint.
    ///
    /// - Parameter block: The PCM block to append; its channel arrays own their storage.
    /// - Throws: An error when the block cannot be written.
    func append(_ block: AudioPCMBlock) async throws

    /// Closes the current checkpoint and makes its media durable.
    ///
    /// - Returns: The commit describing the durable sample range and track files.
    /// - Throws: An error when the checkpoint cannot be committed.
    func commitCheckpoint() async throws -> CheckpointCommit
}

/// Controls the lifecycle of an audio recording session.
public protocol AudioRecordingControlling {
    /// Starts a session with the supplied immutable configuration.
    ///
    /// - Parameter configuration: The audio recording configuration to apply.
    /// - Throws: An error when the session cannot start.
    func start(_ configuration: AudioRecordingConfiguration) async throws

    /// Stops capture and returns the final session outcome.
    ///
    /// - Returns: The final recording result, including published segments.
    func stop() async -> AudioRecordingResult

    /// Applies a source routing change at an integer sample position.
    ///
    /// - Parameter event: The route event to apply.
    /// - Returns: Whether the route change was committed.
    func applyRoute(_ event: RouteEvent) async -> RouteCommitResult

    /// Creates a stream of progress snapshots for observers.
    ///
    /// - Returns: A new progress stream; each observer receives its own stream.
    func makeProgressStream() -> AsyncStream<RecordingProgress>
}
