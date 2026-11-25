import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SharedKit

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

/// Writes one legacy recording session's samples into the transaction's partial file.
///
/// The engine owns stream and lifecycle orchestration; this type owns the legacy
/// single-file writer, finalization, and publication handoff.
final class RecordingWriterPipeline: @unchecked Sendable {
    private let transaction: RecordingOutputTransaction
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let sampleQueue: DispatchQueue
    private let logger = Logger(category: "recording")
    private var sessionStartTime: CMTime?
    private var hasStartedWriting = false
    private(set) var hasAcceptedVideoSample = false
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
            CMSampleBufferDataIsReady(sampleBuffer)
        else {
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
                    self.logger.error("recording: discarding partial — \(reason)")
                    do {
                        try self.discardUnpublishedOutput()
                        continuation.resume(
                            throwing: ScreenRecordingEngineError.recordingFailed(
                                reason,
                                partialURL: nil
                            ))
                    } catch {
                        continuation.resume(
                            throwing: ScreenRecordingEngineError.recordingFailed(
                                reason,
                                partialURL: self.existingPartialURL
                            ))
                    }
                case .retainPartial(let reason):
                    self.logger.error("recording: retaining partial — \(reason)")
                    if self.writer.status == .writing {
                        self.writer.cancelWriting()
                    }
                    continuation.resume(
                        throwing: ScreenRecordingEngineError.finalizationFailed(
                            reason,
                            partialURL: self.existingPartialURL
                        ))
                case .finishWriting:
                    self.logger.info("recording: finishing writer")
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

        if !hasStartedWriting {
            guard writer.startWriting() else {
                setFailure(writer.error?.localizedDescription ?? "The media writer could not start.")
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
            hasStartedWriting = true
            logger.info("recording: writer started at first video frame, pts=\(presentationTime.seconds)")
        }

        guard videoInput.isReadyForMoreMediaData else { return }

        guard videoInput.append(sampleBuffer) else {
            setFailure(writer.error?.localizedDescription ?? "The media writer rejected a video sample.")
            return
        }
        if !hasAcceptedVideoSample {
            logger.info("recording: first video frame accepted at pts=\(presentationTime.seconds)")
        }
        hasAcceptedVideoSample = true
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard hasStartedWriting,
            let audioInput,
            audioInput.isReadyForMoreMediaData
        else {
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
            presentationTime.isNumeric,
            let sessionStartTime,
            CMTimeCompare(presentationTime, sessionStartTime) >= 0
        else {
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
                continuation.resume(
                    throwing: ScreenRecordingEngineError.recordingFailed(
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
                continuation.resume(
                    throwing: ScreenRecordingEngineError.finalizationFailed(
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
