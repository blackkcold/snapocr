import CaptureCore
import CoreGraphics
import Foundation

/// Adapts the app's existing start, stop, retry, and quit flows to screen segments.
@MainActor
struct ScreenRecordingPipelineAdapter {
    typealias StartOperation = (
        ScreenRecordingStartConfiguration,
        @escaping @Sendable (String) -> Void
    ) async throws -> Void
    typealias StopOperation = () async throws -> ScreenRecordingOutcome
    typealias RetryOperation = () async throws -> URL

    private let startOperation: StartOperation
    private let stopOperation: StopOperation
    private let retryOperation: RetryOperation
    private let writtenVideoFrameQuery: @Sendable () async -> Bool
    private let captureFrameQuery: @Sendable () async -> Bool
    private let failureDescriptionQuery: @Sendable () async -> String?
    private let materialRootQuery: @Sendable () async -> URL?
    private let writerDiagnosticsQuery: @Sendable () async -> ScreenWriterDiagnostics?

    /// Creates an adapter backed by the production screen-session coordinator.
    init(coordinator: ScreenRecordingSessionCoordinator) {
        startOperation = { configuration, onFailure in
            try await coordinator.start(configuration, onFailure: onFailure)
        }
        stopOperation = { try await coordinator.stopAndSave() }
        retryOperation = { try await coordinator.retryPublish() }
        writtenVideoFrameQuery = { await coordinator.hasWrittenVideoFrame() }
        captureFrameQuery = { await coordinator.hasAcceptedCaptureFrame() }
        failureDescriptionQuery = { await coordinator.failureDescription() }
        materialRootQuery = { await coordinator.materialRoot() }
        writerDiagnosticsQuery = { await coordinator.writerDiagnostics() }
    }

    /// Creates an adapter around app-owned operations, including pure test fakes.
    init(
        start: @escaping StartOperation,
        stopAndSave: @escaping StopOperation,
        retryPublish: @escaping RetryOperation,
        hasWrittenVideoFrame: @escaping @Sendable () async -> Bool = { false },
        hasAcceptedCaptureFrame: @escaping @Sendable () async -> Bool = { false },
        failureDescription: @escaping @Sendable () async -> String? = { nil },
        materialRoot: @escaping @Sendable () async -> URL? = { nil },
        writerDiagnostics: @escaping @Sendable () async -> ScreenWriterDiagnostics? = { nil }
    ) {
        startOperation = start
        stopOperation = stopAndSave
        retryOperation = retryPublish
        writtenVideoFrameQuery = hasWrittenVideoFrame
        captureFrameQuery = hasAcceptedCaptureFrame
        failureDescriptionQuery = failureDescription
        materialRootQuery = materialRoot
        writerDiagnosticsQuery = writerDiagnostics
    }

    /// Builds the immutable core configuration from the selected screen audio mode.
    nonisolated static func makeStartConfiguration(
        source: RecordingSource,
        video: RecordingConfiguration,
        audioMode: AudioSourceMode,
        audioBitRate: Int,
        destinationDirectory: URL,
        excludedWindowIDs: Set<CGWindowID>,
        sourceDimensions: CGSize? = nil
    ) -> ScreenRecordingStartConfiguration {
        let channels: [RecordingTrackRole: Int]
        switch audioMode {
        case .system:
            channels = [.system: 2]
        case .microphone:
            channels = [.microphone: 1]
        case .systemAndMicrophone:
            channels = [.system: 2, .microphone: 1]
        case .none:
            channels = [:]
        }

        let screenAudio = AudioRecordingConfiguration(
            kind: .screen,
            mode: audioMode,
            layout: .separateTracks,
            sampleRate: 48_000,
            channelCountByRole: channels,
            bitRate: audioBitRate
        )
        let screenVideo = RecordingConfiguration(
            codec: video.codec,
            resolutionLimit: video.resolutionLimit,
            frameRateLimit: video.frameRateLimit,
            averageVideoBitrate: video.averageVideoBitrate,
            maximumKeyFrameIntervalSeconds: video.maximumKeyFrameIntervalSeconds,
            capturesSystemAudio: false
        )
        return ScreenRecordingStartConfiguration(
            source: source,
            video: screenVideo,
            audio: screenAudio,
            destinationDirectory: destinationDirectory,
            excludedWindowIDs: excludedWindowIDs,
            sourceDimensions: sourceDimensions
        )
    }

    /// Starts the screen session using the supplied immutable selection.
    func start(
        _ configuration: ScreenRecordingStartConfiguration,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        try await startOperation(configuration, onFailure)
    }

    /// Stops capture and returns the visible segments that were published.
    func stopAndSave() async throws -> ScreenRecordingOutcome {
        try await stopOperation()
    }

    /// Retries publication through the screen pipeline, without starting capture again.
    func retryPublish() async throws -> URL {
        try await retryOperation()
    }

    /// Whether the video writer has accepted at least one frame for this session.
    ///
    /// This is true only after `AVAssetWriterInput.append` accepts a sample; it is
    /// not queue acceptance in the capture engine.
    func hasWrittenVideoFrame() async -> Bool {
        await writtenVideoFrameQuery()
    }

    /// Whether the capture callback accepted a video sample at the queue level.
    ///
    /// Used only to tell "no frames arrived" apart from "the writer never accepted
    /// one" after the first-frame gate expires.
    func hasAcceptedCaptureFrame() async -> Bool {
        await captureFrameQuery()
    }

    /// The capture or writer failure summary reported for this session, if any.
    func failureDescription() async -> String? {
        await failureDescriptionQuery()
    }

    /// The session's material directory for an actionable recovery hint.
    func materialRoot() async -> URL? {
        await materialRootQuery()
    }

    /// Privacy-safe writer counters for this session, when the pipeline produced any.
    func writerDiagnostics() async -> ScreenWriterDiagnostics? {
        await writerDiagnosticsQuery()
    }
}
