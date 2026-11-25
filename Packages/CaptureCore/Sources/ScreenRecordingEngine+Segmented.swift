import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SharedKit

extension ScreenRecordingEngine {
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
        onVideoFrame: @escaping @Sendable (CMSampleBuffer, UInt64) -> ScreenVideoFrameDisposition,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        // Every session owns exactly one stream. A stream that could not be
        // confirmed stopped keeps this engine unavailable, so two capture
        // sessions can never overlap on the same engine.
        guard stream == nil, !hasUnconfirmedSegmentedStream else {
            throw ScreenRecordingEngineError.previousStreamNotStopped
        }
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
            cachedShareableContent = shareableContent
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
                resolvedSource.dimensions.height > 0
            else {
                throw ScreenRecordingEngineError.invalidSourceDimensions
            }

            let streamConfiguration = try makeSegmentedStreamConfiguration(
                configuration: configuration,
                resolvedSource: resolvedSource,
                audioOutputReuse: audioOutputReuse
            )

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

    private func makeSegmentedStreamConfiguration(
        configuration: ScreenRecordingStartConfiguration,
        resolvedSource: ResolvedSource,
        audioOutputReuse: ScreenAudioOutputReuse?
    ) throws -> SCStreamConfiguration {
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
        return streamConfiguration
    }

    /// Stops the shared capture stream and returns its stop confirmation.
    ///
    /// Files must not be finalized unless `confirmed` is `true`. When
    /// `stopCapture()` throws, the stream and its sample output are deliberately
    /// retained, `hasUnconfirmedStream` is set, and the drop count is left at its
    /// last known value.
    public func stopSegmentedCapture() async -> ScreenCaptureStopResult {
        guard let stream else {
            return ScreenCaptureStopResult(
                droppedFrames: segmentedDroppedFrameCount,
                confirmed: !hasUnconfirmedSegmentedStream
            )
        }
        isStreamCapturing = false
        if sessionState.phase == .recording { try? sessionState.beginStop() }

        do {
            try await stream.stopCapture()
        } catch {
            recordSegmentedFailure("The capture stream could not stop cleanly: \(error.localizedDescription)")
            hasUnconfirmedSegmentedStream = true
            return ScreenCaptureStopResult(
                droppedFrames: segmentedDroppedFrameCount,
                confirmed: false
            )
        }

        hasUnconfirmedSegmentedStream = false
        let videoOutput = segmentedOutput
        let stats = sampleQueue.sync {
            videoOutput?.stopAcceptingSamples()
            return videoOutput?.snapshot
        }
        segmentedAudioOutputReuse?.detach(from: stream)
        if let stats {
            segmentedFailureMessage = segmentedFailureMessage ?? stats.failureMessage
            segmentedDroppedFrameCount = stats.droppedFrameCount
            segmentedHasAcceptedVideoSample = stats.hasAcceptedVideoFrame
        }
        self.stream = nil
        output = nil
        segmentedOutput = nil
        segmentedAudioOutputReuse = nil
        activeSource = nil
        cachedShareableContent = nil
        if sessionState.phase == .stopping { try? sessionState.beginSaving() }
        return ScreenCaptureStopResult(
            droppedFrames: segmentedDroppedFrameCount,
            confirmed: true
        )
    }

    /// Retries one stop after an unconfirmed stop left the stream retained.
    ///
    /// This is the explicit recovery path for ``ScreenCaptureStopResult/confirmed``
    /// being `false`; it never starts a second stream.
    public func confirmSegmentedCaptureStopped() async -> ScreenCaptureStopResult {
        guard hasUnconfirmedSegmentedStream || stream != nil else {
            return ScreenCaptureStopResult(droppedFrames: segmentedDroppedFrameCount, confirmed: true)
        }
        let result = await stopSegmentedCapture()
        if result.confirmed, sessionState.phase != .failed {
            sessionState.fail()
        }
        return result
    }

    /// The last segmented session's capture-callback drop count.
    ///
    /// Read after a stop or failure to complete the three-layer accounting.
    public func captureCallbackDroppedCount() -> Int64 {
        segmentedOutput?.snapshot.droppedFrameCount ?? segmentedDroppedFrameCount
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
        cachedShareableContent = nil
    }

    /// Marks segmented finalization as recoverable while retaining its retry handler.
    ///
    /// An unconfirmed stream is never dropped here: the references stay so a later
    /// confirmation can still stop it, and a new stream stays refused.
    public func failSegmentedSession() async {
        isStreamCapturing = false
        if let stream {
            do {
                try await stream.stopCapture()
                hasUnconfirmedSegmentedStream = false
            } catch {
                recordSegmentedFailure("The capture stream could not stop cleanly: \(error.localizedDescription)")
                hasUnconfirmedSegmentedStream = true
                return
            }
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
        cachedShareableContent = nil
    }

    private func cleanupAfterSegmentedStartFailure() async {
        isStreamCapturing = false
        if let stream {
            do {
                try await stream.stopCapture()
                hasUnconfirmedSegmentedStream = false
            } catch {
                recordSegmentedFailure("The capture stream could not stop cleanly: \(error.localizedDescription)")
                hasUnconfirmedSegmentedStream = true
                return
            }
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
        cachedShareableContent = nil
    }

    private func recordSegmentedFailure(_ message: String) {
        guard segmentedFailureMessage == nil else { return }
        segmentedFailureMessage = message
    }
}
