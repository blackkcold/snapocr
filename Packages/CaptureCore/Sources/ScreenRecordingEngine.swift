import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import SharedKit
@preconcurrency import ScreenCaptureKit

enum RecordingStreamSettings {
    static func make(
        configuration: RecordingConfiguration,
        sourceDimensions: CGSize,
        sourceRect: CGRect? = nil
    ) throws -> SCStreamConfiguration {
        guard let dimensions = configuration.validatedEvenOutputDimensions(for: sourceDimensions) else {
            throw ScreenRecordingEngineError.invalidOutputDimensions
        }
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = Int(dimensions.width)
        streamConfiguration.height = Int(dimensions.height)
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: Int32(clamping: configuration.frameRateLimit)
        )
        streamConfiguration.queueDepth = 3
        streamConfiguration.scalesToFit = false
        streamConfiguration.capturesAudio = configuration.capturesSystemAudio
        if let sourceRect {
            streamConfiguration.sourceRect = sourceRect
        }
        if configuration.capturesSystemAudio {
            streamConfiguration.sampleRate = 48_000
            streamConfiguration.channelCount = 2
        }
        return streamConfiguration
    }
}

/// Errors raised while starting, stopping, or finalizing one recording session.
public enum ScreenRecordingEngineError: LocalizedError, Equatable, Sendable {
    /// The selected display or window is no longer available.
    case sourceUnavailable(String)
    /// The selected region is invalid or lies outside its selected display.
    case invalidRegion
    /// The source does not provide usable pixel dimensions.
    case invalidSourceDimensions
    /// The source cannot produce valid even-sized output pixels.
    case invalidOutputDimensions
    /// AVAssetWriter rejected one of the requested output inputs.
    case writerInputUnavailable(String)
    /// The capture stream or writer failed before a usable video sample was accepted.
    case recordingFailed(String, partialURL: URL?)
    /// The writer could not finish or publish the completed media file.
    case finalizationFailed(String, partialURL: URL?)

    /// English fallback description for presentation layers without app-language localization.
    public var errorDescription: String? {
        switch self {
        case let .sourceUnavailable(reason):
            reason
        case .invalidRegion:
            "The recording region is outside the selected display."
        case .invalidSourceDimensions:
            "The recording source has invalid dimensions."
        case .invalidOutputDimensions:
            "The recording source cannot produce valid even-sized output dimensions."
        case let .writerInputUnavailable(mediaType):
            "The media writer cannot encode the requested \(mediaType) format."
        case let .recordingFailed(reason, partialURL):
            Self.message(reason: reason, partialURL: partialURL)
        case let .finalizationFailed(reason, partialURL):
            Self.message(reason: reason, partialURL: partialURL)
        }
    }

    private static func message(reason: String, partialURL: URL?) -> String {
        guard let partialURL else { return reason }
        return "\(reason) Retained partial: \(partialURL.path)"
    }
}

/// Owns one ScreenCaptureKit stream and AVAssetWriter recording lifecycle.
public actor ScreenRecordingEngine {
    private struct ResolvedSource {
        let filter: SCContentFilter
        let dimensions: CGSize
        let sourceRect: CGRect?
    }

    private let sampleQueue = DispatchQueue(
        label: "com.snapglass.capture.recording-samples",
        qos: .userInitiated
    )
    private let logger = Logger(category: "recording")

    private var sessionState = RecordingSessionState()
    private var stream: SCStream?
    private var output: RecordingSampleOutput?
    private var segmentedOutput: SegmentedRecordingSampleOutput?
    private var segmentedAudioOutputReuse: ScreenAudioOutputReuse?
    private var segmentedRetryHandler: (@Sendable () async throws -> URL)?
    private var segmentedFailureMessage: String?
    private var segmentedDroppedFrameCount: Int64 = 0
    private var segmentedHasAcceptedVideoSample = false
    private var pipeline: RecordingWriterPipeline?
    private var transaction: RecordingOutputTransaction?
    private var activeSource: RecordingSource?
    private var excludedWindowIDs: Set<CGWindowID> = []
    private var exclusionRevision: UInt64 = 0
    private var appliedExclusionRevision: UInt64 = 0
    private var hasReceivedExclusionUpdate = false
    private var isStreamCapturing = false
    private var isContentFilterUpdateInFlight = false

    /// Creates an unused recording engine.
    public init() {}

    /// Installs the segmented screen pipeline's retry operation for the legacy HUD entry point.
    public func installSegmentedRetryHandler(
        _ handler: (@Sendable () async throws -> URL)?
    ) {
        segmentedRetryHandler = handler
    }

    /// The first failure reported by the active segmented screen pipeline, if any.
    public func segmentedFailureDescription() -> String? {
        segmentedFailureMessage ?? segmentedOutput?.failureMessage
    }

    /// Starts one segmented session on this engine's single ScreenCaptureKit stream.
    ///
    /// Screen samples are forwarded to the supplied bounded consumer. When an audio reuse
    /// output is supplied, it is attached to this same stream; this method never creates a
    /// second stream or a legacy single-file writer.
    public func startSegmented(
        _ configuration: ScreenRecordingStartConfiguration,
        audioOutputReuse: ScreenAudioOutputReuse?,
        onVideoFrame: @escaping @Sendable (CMSampleBuffer, UInt64) -> Bool,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        try sessionState.beginStart()
        activeSource = configuration.source
        if !hasReceivedExclusionUpdate {
            excludedWindowIDs = configuration.excludedWindowIDs
            exclusionRevision &+= 1
        }
        isStreamCapturing = false
        segmentedFailureMessage = nil
        segmentedDroppedFrameCount = 0
        segmentedHasAcceptedVideoSample = false

        do {
            try configuration.video.validate()
            let shareableContent = try await SCShareableContent.current
            let initialExcludedWindowIDs = excludedWindowIDs
            let initialExclusionRevision = exclusionRevision
            let resolvedSource = try resolve(
                configuration.source,
                in: shareableContent,
                excludedWindowIDs: initialExcludedWindowIDs
            )
            guard resolvedSource.dimensions.width.isFinite,
                  resolvedSource.dimensions.height.isFinite,
                  resolvedSource.dimensions.width > 0,
                  resolvedSource.dimensions.height > 0 else {
                throw ScreenRecordingEngineError.invalidSourceDimensions
            }

            let streamConfiguration = try RecordingStreamSettings.make(
                configuration: configuration.video,
                sourceDimensions: resolvedSource.dimensions,
                sourceRect: resolvedSource.sourceRect
            )
            streamConfiguration.capturesAudio = audioOutputReuse != nil
            if audioOutputReuse != nil {
                streamConfiguration.sampleRate = 48_000
                streamConfiguration.channelCount = 2
            }

            let segmentedOutput = SegmentedRecordingSampleOutput(
                sampleQueue: sampleQueue,
                onVideoFrame: onVideoFrame,
                onFailure: { [weak self] message in
                    Task { await self?.recordSegmentedFailure(message) }
                    onFailure(message)
                }
            )
            self.segmentedOutput = segmentedOutput
            segmentedAudioOutputReuse = audioOutputReuse

            let stream = SCStream(
                filter: resolvedSource.filter,
                configuration: streamConfiguration,
                delegate: segmentedOutput
            )
            self.stream = stream
            try stream.addStreamOutput(
                segmentedOutput,
                type: .screen,
                sampleHandlerQueue: sampleQueue
            )
            try audioOutputReuse?.attach(to: stream)
            try await stream.startCapture()
            isStreamCapturing = true
            appliedExclusionRevision = initialExclusionRevision
            try sessionState.recordingDidStart()
            await applyLatestExcludedWindowFilter()
        } catch {
            await cleanupAfterSegmentedStartFailure()
            throw error
        }
    }

    /// Stops the shared capture stream and returns its bounded callback-drop count.
    public func stopSegmentedCapture() async -> Int64 {
        guard let stream, let segmentedOutput else { return segmentedDroppedFrameCount }
        isStreamCapturing = false
        if sessionState.phase == .recording { try? sessionState.beginStop() }

        do {
            try await stream.stopCapture()
        } catch {
            recordSegmentedFailure("The capture stream could not stop cleanly: \(error.localizedDescription)")
        }

        let stats = sampleQueue.sync {
            segmentedOutput.stopAcceptingSamples()
            return segmentedOutput.snapshot
        }
        segmentedAudioOutputReuse?.detach(from: stream)
        segmentedFailureMessage = segmentedFailureMessage ?? stats.failureMessage
        segmentedDroppedFrameCount = stats.droppedFrameCount
        segmentedHasAcceptedVideoSample = stats.hasAcceptedVideoFrame
        self.stream = nil
        output = nil
        self.segmentedOutput = nil
        segmentedAudioOutputReuse = nil
        activeSource = nil
        if sessionState.phase == .stopping { try? sessionState.beginSaving() }
        return segmentedDroppedFrameCount
    }

    /// Completes the segmented lifecycle after sealing and publication have succeeded.
    public func finishSegmentedSession() throws {
        if sessionState.phase == .saving { try sessionState.finish() }
        segmentedRetryHandler = nil
        segmentedOutput = nil
        segmentedAudioOutputReuse = nil
        stream = nil
        output = nil
        activeSource = nil
    }

    /// Marks segmented finalization as recoverable while retaining its retry handler.
    public func failSegmentedSession() async {
        isStreamCapturing = false
        if let stream {
            try? await stream.stopCapture()
            segmentedAudioOutputReuse?.detach(from: stream)
        }
        if let segmentedOutput {
            let stats = sampleQueue.sync {
                segmentedOutput.stopAcceptingSamples()
                return segmentedOutput.snapshot
            }
            segmentedFailureMessage = segmentedFailureMessage ?? stats.failureMessage
            segmentedDroppedFrameCount = max(segmentedDroppedFrameCount, stats.droppedFrameCount)
            segmentedHasAcceptedVideoSample = segmentedHasAcceptedVideoSample || stats.hasAcceptedVideoFrame
        }
        sessionState.fail()
        stream = nil
        output = nil
        segmentedOutput = nil
        segmentedAudioOutputReuse = nil
        activeSource = nil
    }

    private func cleanupAfterSegmentedStartFailure() async {
        isStreamCapturing = false
        if let stream {
            try? await stream.stopCapture()
            segmentedAudioOutputReuse?.detach(from: stream)
        }
        if let segmentedOutput {
            _ = sampleQueue.sync {
                segmentedOutput.stopAcceptingSamples()
                return segmentedOutput.snapshot
            }
        } else {
            sampleQueue.sync {}
        }
        sessionState.fail()
        stream = nil
        output = nil
        segmentedOutput = nil
        segmentedAudioOutputReuse = nil
        pipeline = nil
        transaction = nil
        activeSource = nil
    }

    private func recordSegmentedFailure(_ message: String) {
        guard segmentedFailureMessage == nil else { return }
        segmentedFailureMessage = message
    }

    /// Current lifecycle phase for this single recording session.
    public var phase: RecordingSessionState.Phase {
        sessionState.phase
    }

    /// Existing hidden partial output, if one remains after a failed session.
    public var partialOutputURL: URL? {
        guard let transaction,
              FileManager.default.fileExists(atPath: transaction.partialURL.path) else {
            return nil
        }
        return transaction.partialURL
    }

    /// Whether the active session has written at least one video frame.
    ///
    /// Used by the control panel watchdog to distinguish "recording" from "recording but the
    /// source delivers no frames", which otherwise looks identical to the user.
    public var hasAcceptedVideoFrame: Bool {
        pipeline?.hasAcceptedVideoSample
            ?? segmentedOutput?.snapshot.hasAcceptedVideoFrame
            ?? segmentedHasAcceptedVideoSample
    }

    /// Whether the retained partial of a failed session can be published again.
    public var canRetryPublish: Bool {
        transaction?.isPublishable ?? (segmentedRetryHandler != nil && hasAcceptedVideoFrame)
    }

    /// Starts capture for one display, one window, or a display-local region.
    ///
    /// Only the supplied window IDs are excluded from display/region capture; the
    /// application process itself is never excluded.
    ///
    /// - Parameters:
    ///   - source: Exactly one display, window, or rectangle on a display.
    ///   - configuration: Immutable settings for this session.
    ///   - destinationDirectory: Existing directory for the final and partial files.
    ///   - excludedWindowIDs: Specific control-window IDs to omit from display capture.
    ///   - onFailure: Called once on the sample queue for the first writer or stream failure.
    /// - Throws: A source, writer-capability, stream-start, or configuration error.
    public func start(
        source: RecordingSource,
        configuration: RecordingConfiguration,
        destinationDirectory: URL,
        excludedWindowIDs: Set<CGWindowID> = [],
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws {
        try sessionState.beginStart()
        activeSource = source
        if !hasReceivedExclusionUpdate {
            self.excludedWindowIDs = excludedWindowIDs
            exclusionRevision &+= 1
        }
        isStreamCapturing = false

        do {
            try configuration.validate()
            let shareableContent = try await SCShareableContent.current
            let initialExcludedWindowIDs = self.excludedWindowIDs
            let initialExclusionRevision = exclusionRevision
            let resolvedSource = try resolve(
                source,
                in: shareableContent,
                excludedWindowIDs: initialExcludedWindowIDs
            )
            guard resolvedSource.dimensions.width.isFinite,
                  resolvedSource.dimensions.height.isFinite,
                  resolvedSource.dimensions.width > 0,
                  resolvedSource.dimensions.height > 0 else {
                throw ScreenRecordingEngineError.invalidSourceDimensions
            }

            let streamConfiguration = try RecordingStreamSettings.make(
                configuration: configuration,
                sourceDimensions: resolvedSource.dimensions,
                sourceRect: resolvedSource.sourceRect
            )
            let transaction = try RecordingOutputTransaction(destinationDirectory: destinationDirectory)
            self.transaction = transaction
            let pipeline = try RecordingWriterPipeline(
                transaction: transaction,
                configuration: configuration,
                dimensions: CGSize(width: streamConfiguration.width, height: streamConfiguration.height),
                sampleQueue: sampleQueue,
                onFailure: onFailure
            )
            self.pipeline = pipeline

            let output = RecordingSampleOutput(pipeline: pipeline)
            self.output = output
            let stream = SCStream(
                filter: resolvedSource.filter,
                configuration: streamConfiguration,
                delegate: output
            )
            self.stream = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            if configuration.capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            try await stream.startCapture()
            isStreamCapturing = true
            appliedExclusionRevision = initialExclusionRevision
            try sessionState.recordingDidStart()
            await applyLatestExcludedWindowFilter()
        } catch let startError {
            if let cleanupError = await cleanupAfterStartFailure(startError) {
                throw cleanupError
            }
            throw startError
        }
    }

    private func cleanupAfterStartFailure(_ startError: any Error) async -> ScreenRecordingEngineError? {
        isStreamCapturing = false
        if let stream {
            try? await stream.stopCapture()
        }
        pipeline?.stopAcceptingSamples()
        sampleQueue.sync {}

        var cleanupFailed = false
        do {
            if let activePipeline = pipeline {
                try sampleQueue.sync {
                    try activePipeline.discardUnpublishedOutput()
                }
            } else if let transaction {
                try transaction.discardPartial()
            }
        } catch {
            cleanupFailed = true
        }

        let retainedPartialURL = cleanupFailed ? partialOutputURL : nil
        sessionState.fail()
        self.stream = nil
        output = nil
        pipeline = nil
        transaction = nil
        activeSource = nil
        guard let retainedPartialURL else { return nil }
        return .recordingFailed(startError.localizedDescription, partialURL: retainedPartialURL)
    }

    /// Stops capture, drains queued samples, finalizes the writer, and publishes the MP4.
    ///
    /// - Returns: The unique final recording URL.
    /// - Throws: A lifecycle, stream, writer, or safe-publication error. Any retained
    ///   partial remains at `partialOutputURL`; its playability is not guaranteed.
    public func stopAndSave() async throws -> URL {
        try sessionState.beginStop()
        guard let stream, let pipeline else {
            sessionState.fail()
            throw ScreenRecordingEngineError.recordingFailed(
                "The recording session is unavailable.",
                partialURL: partialOutputURL
            )
        }

        isStreamCapturing = false
        var stopError: String?
        do {
            try await stream.stopCapture()
        } catch {
            stopError = error.localizedDescription
        }

        pipeline.stopAcceptingSamples()
        sampleQueue.sync {}
        try sessionState.beginSaving()

        do {
            let finalURL = try await pipeline.finishAndPublish(stopError: stopError)
            try sessionState.finish()
            self.stream = nil
            output = nil
            self.pipeline = nil
            transaction = nil
            activeSource = nil
            return finalURL
        } catch {
            sessionState.fail()
            activeSource = nil
            if stopError == nil {
                self.stream = nil
                output = nil
            }
            throw error
        }
    }

    /// Publishes the retained partial of a failed session without capturing again.
    ///
    /// - Returns: The unique final recording URL.
    /// - Throws: `ScreenRecordingEngineError.finalizationFailed` when nothing is publishable or the
    ///   destination still refuses the file.
    public func retryPublish() async throws -> URL {
        if let segmentedRetryHandler { return try await segmentedRetryHandler() }
        guard let transaction, transaction.isPublishable else {
            throw ScreenRecordingEngineError.finalizationFailed(
                "The retained recording cannot be published.",
                partialURL: partialOutputURL
            )
        }
        do {
            let url = try transaction.publish()
            logger.info("recording: republished retained partial to \(url.path)")
            self.transaction = nil
            return url
        } catch {
            throw ScreenRecordingEngineError.finalizationFailed(
                error.localizedDescription,
                partialURL: transaction.partialURL
            )
        }
    }

    /// Updates display/region window exclusions without stopping the capture stream or writer.
    /// Window-source recordings already include only the selected window, so their filter is
    /// independent of the app's floating control windows.
    public func updateExcludedWindowIDs(_ windowIDs: Set<CGWindowID>) async {
        hasReceivedExclusionUpdate = true
        if excludedWindowIDs != windowIDs {
            excludedWindowIDs = windowIDs
            exclusionRevision &+= 1
        } else if appliedExclusionRevision == exclusionRevision {
            return
        }

        guard isStreamCapturing else { return }
        await applyLatestExcludedWindowFilter()
    }

    private func applyLatestExcludedWindowFilter() async {
        guard !isContentFilterUpdateInFlight else { return }
        isContentFilterUpdateInFlight = true
        defer { isContentFilterUpdateInFlight = false }

        while appliedExclusionRevision != exclusionRevision {
            guard isStreamCapturing,
                  let stream,
                  let activeSource else { return }
            let revision = exclusionRevision

            if case .window = activeSource {
                appliedExclusionRevision = revision
                continue
            }

            do {
                let shareableContent = try await SCShareableContent.current
                guard revision == exclusionRevision else { continue }
                let resolvedSource = try resolve(
                    activeSource,
                    in: shareableContent,
                    excludedWindowIDs: excludedWindowIDs
                )
                try await stream.updateContentFilter(resolvedSource.filter)
                appliedExclusionRevision = revision
            } catch {
                logger.warning("recording: excluded-window filter update failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func resolve(
        _ source: RecordingSource,
        in content: SCShareableContent,
        excludedWindowIDs: Set<CGWindowID>
    ) throws -> ResolvedSource {
        let excludedWindows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }

        switch source {
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingEngineError.sourceUnavailable("The selected display is no longer available.")
            }
            return ResolvedSource(
                filter: SCContentFilter(display: display, excludingWindows: excludedWindows),
                dimensions: CGSize(width: display.width, height: display.height),
                sourceRect: nil
            )

        case let .window(windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }),
                  let display = content.displays.first(where: { $0.frame.contains(window.frame) }) else {
                throw ScreenRecordingEngineError.sourceUnavailable(
                    "The selected window is no longer fully visible on one display."
                )
            }
            let scale = Self.pixelScale(for: display)
            let sourceRect = CGRect(
                x: window.frame.minX - display.frame.minX,
                y: window.frame.minY - display.frame.minY,
                width: window.frame.width,
                height: window.frame.height
            )
            return ResolvedSource(
                filter: SCContentFilter(display: display, including: [window]),
                dimensions: CGSize(width: window.frame.width * scale.width, height: window.frame.height * scale.height),
                sourceRect: sourceRect
            )

        case let .region(displayID, sourceRect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingEngineError.sourceUnavailable("The selected display is no longer available.")
            }
            let region = sourceRect.standardized
            let displayBounds = CGRect(origin: .zero, size: display.frame.size)
            guard Self.isFinite(region),
                  region.width > 0,
                  region.height > 0,
                  displayBounds.contains(region) else {
                throw ScreenRecordingEngineError.invalidRegion
            }
            let scale = Self.pixelScale(for: display)
            return ResolvedSource(
                filter: SCContentFilter(display: display, excludingWindows: excludedWindows),
                dimensions: CGSize(width: region.width * scale.width, height: region.height * scale.height),
                sourceRect: region
            )
        }
    }

    private static func pixelScale(for display: SCDisplay) -> CGSize {
        guard display.frame.width > 0, display.frame.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(
            width: CGFloat(display.width) / display.frame.width,
            height: CGFloat(display.height) / display.frame.height
        )
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}

private final class RecordingSampleOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let pipeline: RecordingWriterPipeline

    init(pipeline: RecordingWriterPipeline) {
        self.pipeline = pipeline
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        pipeline.append(sampleBuffer, type: outputType)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        pipeline.recordStreamFailure(error.localizedDescription)
    }
}

private final class SegmentedRecordingSampleOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Snapshot {
        let droppedFrameCount: Int64
        let hasAcceptedVideoFrame: Bool
        let failureMessage: String?
    }

    private let sampleQueue: DispatchQueue
    private let onVideoFrame: @Sendable (CMSampleBuffer, UInt64) -> Bool
    private let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var acceptsSamples = true
    private var droppedFrameCount: Int64 = 0
    private var hasAcceptedVideoFrame = false
    private var recordedFailureMessage: String?

    init(
        sampleQueue: DispatchQueue,
        onVideoFrame: @escaping @Sendable (CMSampleBuffer, UInt64) -> Bool,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.sampleQueue = sampleQueue
        self.onVideoFrame = onVideoFrame
        self.onFailure = onFailure
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        guard outputType == .screen else { return }
        lock.lock()
        let shouldAccept = acceptsSamples
        lock.unlock()
        guard shouldAccept else { return }

        let delivered = onVideoFrame(sampleBuffer, AudioGetCurrentHostTime())
        lock.lock()
        if delivered {
            hasAcceptedVideoFrame = true
        } else {
            droppedFrameCount += 1
        }
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        recordFailure(error.localizedDescription)
    }

    func stopAcceptingSamples() {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        lock.lock()
        acceptsSamples = false
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            droppedFrameCount: droppedFrameCount,
            hasAcceptedVideoFrame: hasAcceptedVideoFrame,
            failureMessage: failureMessage
        )
    }

    var failureMessage: String? { snapshot.failureMessage }

    private func recordFailure(_ message: String) {
        lock.lock()
        let shouldNotify = recordedFailureMessage == nil
        if shouldNotify { recordedFailureMessage = message }
        lock.unlock()
        if shouldNotify { onFailure(message) }
    }
}
