import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
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

enum RecordingWriterFinalizationDecision: Equatable {
    case discardPartial(reason: String)
    case retainPartial(reason: String)
    case finishWriting
    case publish

    static func beforeFinishing(
        hasAcceptedVideoSample: Bool,
        writerIsWriting: Bool,
        failureMessage: String?,
        writerError: String?
    ) -> Self {
        guard hasAcceptedVideoSample else {
            return .discardPartial(reason: failureMessage ?? "No video frame was captured.")
        }
        guard writerIsWriting else {
            return .retainPartial(
                reason: writerError ?? failureMessage ?? "The media writer did not finish successfully."
            )
        }
        return .finishWriting
    }

    static func afterFinishing(
        hasAcceptedVideoSample: Bool,
        writerCompleted: Bool,
        failureMessage: String?,
        writerError: String?
    ) -> Self {
        guard hasAcceptedVideoSample else {
            return .discardPartial(reason: failureMessage ?? "No video frame was captured.")
        }
        guard writerCompleted else {
            return .retainPartial(
                reason: writerError ?? failureMessage ?? "The media writer did not finish successfully."
            )
        }
        guard let failureMessage else { return .publish }
        return .retainPartial(reason: failureMessage)
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

    private var sessionState = RecordingSessionState()
    private var stream: SCStream?
    private var output: RecordingSampleOutput?
    private var pipeline: RecordingWriterPipeline?
    private var transaction: RecordingOutputTransaction?

    /// Creates an unused recording engine.
    public init() {}

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

        do {
            try configuration.validate()
            let shareableContent = try await SCShareableContent.current
            let resolvedSource = try resolve(
                source,
                in: shareableContent,
                excludedWindowIDs: excludedWindowIDs
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
            try sessionState.recordingDidStart()
        } catch let startError {
            if let cleanupError = await cleanupAfterStartFailure(startError) {
                throw cleanupError
            }
            throw startError
        }
    }

    private func cleanupAfterStartFailure(_ startError: any Error) async -> ScreenRecordingEngineError? {
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
            throw ScreenRecordingEngineError.recordingFailed("The recording session is unavailable.", partialURL: partialOutputURL)
        }

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
            return finalURL
        } catch {
            sessionState.fail()
            if stopError == nil {
                self.stream = nil
                output = nil
            }
            throw error
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
                throw ScreenRecordingEngineError.sourceUnavailable("The selected window is no longer fully visible on one display.")
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

private final class RecordingWriterPipeline: @unchecked Sendable {
    private let transaction: RecordingOutputTransaction
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let sampleQueue: DispatchQueue
    private var sessionStartTime: CMTime?
    private var hasStartedWriting = false
    private var hasAcceptedVideoSample = false
    private var acceptsSamples = true
    private var failureRelay: RecordingFailureRelay

    private var failureMessage: String? {
        failureRelay.message
    }

    var partialURL: URL {
        transaction.partialURL
    }

    init(
        transaction: RecordingOutputTransaction,
        configuration: RecordingConfiguration,
        dimensions: CGSize,
        sampleQueue: DispatchQueue,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        self.transaction = transaction
        self.sampleQueue = sampleQueue
        failureRelay = RecordingFailureRelay(onFailure: onFailure)
        try transaction.prepareForWriting()

        let writer = try AVAssetWriter(outputURL: transaction.partialURL, fileType: .mp4)
        let supportedCodecs = RecordingWriterSettings.supportedVideoCodecs(
            configuration: configuration,
            dimensions: dimensions
        ) { outputSettings in
            writer.canApply(outputSettings: outputSettings, forMediaType: .video)
        }
        try configuration.validate(supportedCodecs: supportedCodecs)

        let videoSettings = RecordingWriterSettings.videoOutputSettings(
            configuration: configuration,
            dimensions: dimensions
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingEngineError.writerInputUnavailable("video")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if configuration.capturesSystemAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: RecordingWriterSettings.audioOutputSettings()
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw ScreenRecordingEngineError.writerInputUnavailable("AAC audio")
            }
            writer.add(input)
            audioInput = input
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        guard acceptsSamples,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        switch type {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func recordStreamFailure(_ message: String) {
        sampleQueue.async {
            self.setFailure(message)
        }
    }

    func stopAcceptingSamples() {
        sampleQueue.sync {
            acceptsSamples = false
        }
    }

    func finishAndPublish(stopError: String?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async {
                self.acceptsSamples = false
                if let stopError {
                    self.setFailure("The capture stream could not stop cleanly: \(stopError)")
                }
                let decision = RecordingWriterFinalizationDecision.beforeFinishing(
                    hasAcceptedVideoSample: self.hasAcceptedVideoSample,
                    writerIsWriting: self.writer.status == .writing,
                    failureMessage: self.failureMessage,
                    writerError: self.writer.error?.localizedDescription
                )
                switch decision {
                case .discardPartial(let reason):
                    do {
                        try self.discardUnpublishedOutput()
                        continuation.resume(throwing: ScreenRecordingEngineError.recordingFailed(
                            reason,
                            partialURL: nil
                        ))
                    } catch {
                        continuation.resume(throwing: ScreenRecordingEngineError.recordingFailed(
                            reason,
                            partialURL: self.existingPartialURL
                        ))
                    }
                case .retainPartial(let reason):
                    continuation.resume(throwing: ScreenRecordingEngineError.finalizationFailed(
                        reason,
                        partialURL: self.existingPartialURL
                    ))
                case .finishWriting:
                    self.videoInput.markAsFinished()
                    self.audioInput?.markAsFinished()
                    self.writer.finishWriting {
                        self.sampleQueue.async {
                            self.completeWriting(continuation: continuation)
                        }
                    }
                case .publish:
                    continuation.resume(throwing: self.writerFailure())
                }
            }
        }
    }

    func discardUnpublishedOutput() throws {
        dispatchPrecondition(condition: .onQueue(sampleQueue))
        acceptsSamples = false
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try transaction.discardPartial()
    }

    private var existingPartialURL: URL? {
        FileManager.default.fileExists(atPath: partialURL.path) ? partialURL : nil
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.imageBuffer != nil else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        if !hasStartedWriting {
            guard writer.startWriting() else {
                setFailure(writer.error?.localizedDescription ?? "The media writer could not start.")
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
            hasStartedWriting = true
        }

        guard videoInput.append(sampleBuffer) else {
            setFailure(writer.error?.localizedDescription ?? "The media writer rejected a video sample.")
            return
        }
        hasAcceptedVideoSample = true
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard hasStartedWriting,
              let audioInput,
              audioInput.isReadyForMoreMediaData else {
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
              presentationTime.isNumeric,
              let sessionStartTime,
              CMTimeCompare(presentationTime, sessionStartTime) >= 0 else {
            return
        }
        guard audioInput.append(sampleBuffer) else {
            setFailure(writer.error?.localizedDescription ?? "The media writer rejected an audio sample.")
            return
        }
    }

    private func completeWriting(continuation: CheckedContinuation<URL, any Error>) {
        let decision = RecordingWriterFinalizationDecision.afterFinishing(
            hasAcceptedVideoSample: hasAcceptedVideoSample,
            writerCompleted: writer.status == .completed,
            failureMessage: failureMessage,
            writerError: writer.error?.localizedDescription
        )
        switch decision {
        case .discardPartial(let reason):
            do {
                try discardUnpublishedOutput()
                continuation.resume(throwing: ScreenRecordingEngineError.recordingFailed(reason, partialURL: nil))
            } catch {
                continuation.resume(throwing: ScreenRecordingEngineError.recordingFailed(
                    reason,
                    partialURL: existingPartialURL
                ))
            }
        case .retainPartial(let reason):
            let error: ScreenRecordingEngineError
            if writer.status == .completed, failureMessage != nil {
                error = .recordingFailed(reason, partialURL: existingPartialURL)
            } else {
                error = .finalizationFailed(reason, partialURL: existingPartialURL)
            }
            continuation.resume(throwing: error)
        case .finishWriting:
            continuation.resume(throwing: writerFailure())
        case .publish:
            do {
                try transaction.markWriterFinished()
                let finalURL = try transaction.publish()
                continuation.resume(returning: finalURL)
            } catch {
                continuation.resume(throwing: ScreenRecordingEngineError.finalizationFailed(
                    error.localizedDescription,
                    partialURL: existingPartialURL
                ))
            }
        }
    }

    private func writerFailure() -> ScreenRecordingEngineError {
        .finalizationFailed(
            writer.error?.localizedDescription ?? "The media writer did not finish successfully.",
            partialURL: existingPartialURL
        )
    }

    private func setFailure(_ message: String) {
        failureRelay.record(message)
    }
}

struct RecordingFailureRelay {
    private(set) var message: String?
    private let onFailure: @Sendable (String) -> Void

    init(onFailure: @escaping @Sendable (String) -> Void) {
        self.onFailure = onFailure
    }

    mutating func record(_ message: String) {
        guard self.message == nil else { return }
        self.message = message
        onFailure(message)
    }
}
