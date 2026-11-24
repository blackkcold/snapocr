import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

private struct ExportFileManagerBox: @unchecked Sendable {
    let value: FileManager
}

/// Writes one export at a time. Work is detached from the caller's executor so
/// synchronous AVAssetReader calls and bounded PCM processing never run on UI.
public actor RecordingCompositionExporter {
    private let fileManager: ExportFileManagerBox
    private var exportInProgress = false

    public init(fileManager: FileManager = .default) {
        self.fileManager = ExportFileManagerBox(value: fileManager)
    }

    public func export(
        _ plan: ExportPlan,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult {
        guard !exportInProgress else { throw ExportError.exportInProgress }
        exportInProgress = true
        defer { exportInProgress = false }

        let fileManager = self.fileManager
        let task = Task.detached(priority: .userInitiated) {
            try await RecordingExportWorker.run(plan, fileManager: fileManager.value, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private enum RecordingExportWorker {
    static func run(
        _ originalPlan: ExportPlan,
        fileManager: FileManager,
        progress callback: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult {
        let progress = ExportProgressThrottle(callback)
        let resources = ExportExecutionResources()
        var transaction: RecordingOutputTransaction?
        progress.emit(0, phase: "revalidating", force: true)

        do {
            let plan = try await revalidateActualMedia(originalPlan)
            try Task.checkCancellation()
            let request = try outputRequest(for: plan)
            let outputTransaction: RecordingOutputTransaction
            do {
                outputTransaction = try RecordingOutputTransaction(request: request, fileManager: fileManager)
            } catch RecordingOutputTransactionError.invalidDestinationDirectory {
                throw ExportError.destinationUnavailable
            } catch {
                throw ExportError.publishFailed(stagingURL: nil)
            }
            transaction = outputTransaction
            let stageURL = outputTransaction.partialURL

            let sourceURLs = plan.audioSourcesBySegment.values.flatMap(\.urls)
                + plan.sourceRanges.flatMap(\.sourceFiles)
            let finalPath = canonicalPath(outputTransaction.finalURL)
            guard !sourceURLs.contains(where: { canonicalPath($0) == finalPath }),
                  canonicalPath(stageURL) != finalPath
            else { throw ExportError.destinationUnavailable }

            try outputTransaction.prepareForWriting()
            try Task.checkCancellation()
            progress.emit(0.04, phase: "preparing")

            let roles = orderedOutputRoles(plan)
            guard !roles.isEmpty else { throw ExportError.missingSource }
            if plan.videoPassthrough {
                try await exportVideoComposition(
                    plan, outputURL: stageURL, roles: roles,
                    resources: resources, progress: progress
                )
            } else if case .directory = plan.outputSpec.shape {
                try await exportSeparatedAudioDirectory(
                    plan, stagingURL: stageURL, roles: roles,
                    resources: resources, progress: progress
                )
            } else {
                try await exportAudioFile(
                    plan, outputURL: stageURL, roles: roles,
                    resources: resources, progress: progress
                )
            }

            try Task.checkCancellation()
            try outputTransaction.markWriterFinished()
            progress.emit(0.92, phase: "publishing")
            let publishedURL = try outputTransaction.publish()
            let outputFacts = inspectOutput(at: publishedURL, shape: plan.outputSpec.shape, fileManager: fileManager)
            progress.emit(1, phase: "complete", force: true)
            return ExportResult(
                outputURL: publishedURL,
                actualDuration: outputFacts.duration,
                videoPassthrough: plan.videoPassthrough,
                audioOperation: plan.audioOperation,
                trackCount: outputFacts.trackCount
            )
        } catch {
            resources.cancel()
            guard let transaction else {
                if Task.isCancelled { throw ExportError.cancelled(stagingURL: nil) }
                throw error
            }
            let stageURL = transaction.partialURL
            preserveStage(stageURL, directory: transaction.isDirectoryOutput, fileManager: fileManager)
            if Task.isCancelled || error is CancellationError {
                throw ExportError.cancelled(stagingURL: stageURL)
            }
            if let exportError = error as? ExportError {
                switch exportError {
                case .cancelled:
                    throw ExportError.cancelled(stagingURL: stageURL)
                case .exportInProgress, .emptySelection, .overLimit, .incompatibleCodec,
                     .missingSource, .destinationUnavailable, .passthroughUnsupported:
                    throw ExportError.publishFailed(stagingURL: stageURL)
                case .publishFailed:
                    throw ExportError.publishFailed(stagingURL: stageURL)
                }
            }
            throw ExportError.publishFailed(stagingURL: stageURL)
        }
    }

    private static func revalidateActualMedia(_ plan: ExportPlan) async throws -> ExportPlan {
        guard !plan.clips.isEmpty else { throw ExportError.emptySelection }
        var actualRanges = plan.effectiveRanges
        if plan.videoPassthrough {
            for clip in plan.clips {
                try Task.checkCancellation()
                guard let source = plan.sourceRanges.first(where: { $0.segmentID == clip.segmentID }),
                      let url = source.sourceFiles.first(where: { $0.pathExtension.lowercased() == "mp4" }),
                      let videoRange = clip.videoRange
                else { throw ExportError.missingSource }
                let actual = try RecordingExportPlanner.inspectVideoRange(
                    url: url,
                    trackIndex: source.videoTrackIndex ?? 0,
                    segmentStartSample: source.segmentRange.startSample,
                    segmentSampleCount: source.segmentRange.sampleCount,
                    requested: clip.requestedRange
                )
                guard actual.codec == plan.outputSpec.videoCodec, actual.range == videoRange else {
                    throw ExportError.passthroughUnsupported
                }
                actualRanges[clip.segmentID] = actual.effective
            }
        }
        return try RecordingExportPlanner.revalidate(plan, actualRanges: actualRanges)
    }

    private static func outputRequest(for plan: ExportPlan) throws -> RecordingOutputRequest {
        let shape: RecordingOutputRequest.Shape
        switch plan.outputSpec.shape {
        case .singleFile(let fileExtension): shape = .singleFile(fileExtension: fileExtension)
        case .directory: shape = .directory
        }
        return try RecordingOutputRequest(
            destinationDirectory: plan.outputSpec.destination.directory,
            stem: plan.outputSpec.destination.stem,
            segmentIndex: plan.clips.first?.index ?? 0,
            shape: shape
        )
    }

    private static func orderedOutputRoles(_ plan: ExportPlan) -> [RecordingTrackRole] {
        RecordingCheckpointWriter.roleOrder.filter { plan.trackMap[$0] != nil }
    }

    private static func exportAudioFile(
        _ plan: ExportPlan,
        outputURL: URL,
        roles: [RecordingTrackRole],
        resources: ExportExecutionResources,
        progress: ExportProgressThrottle
    ) async throws {
        guard roles.count == 1, let role = roles.first else { throw ExportError.passthroughUnsupported }
        let channels = plan.outputSpec.audioFormat.channelCountByRole[role] ?? 2
        let writer = try ExportAssetWriter.audioFile(
            at: outputURL, sampleRate: plan.outputSpec.audioFormat.sampleRate,
            channelsByRole: [role: channels]
        )
        resources.add(writer.writer)
        try writer.start()
        try await renderAudio(plan, sinks: writer.audioSinks, progress: progress, baseFraction: 0.08, span: 0.78)
        try Task.checkCancellation()
        await writer.finish()
        guard writer.writer.status == .completed else { throw ExportError.publishFailed(stagingURL: outputURL) }
    }

    private static func exportSeparatedAudioDirectory(
        _ plan: ExportPlan,
        stagingURL: URL,
        roles: [RecordingTrackRole],
        resources: ExportExecutionResources,
        progress: ExportProgressThrottle
    ) async throws {
        guard !roles.isEmpty else { throw ExportError.missingSource }
        var writers: [ExportAssetWriter] = []
        for role in roles {
            let url = stagingURL.appendingPathComponent("\(roleToken(role)).m4a")
            let writer = try ExportAssetWriter.audioFile(
                at: url, sampleRate: plan.outputSpec.audioFormat.sampleRate,
                channelsByRole: [role: plan.outputSpec.audioFormat.channelCountByRole[role] ?? 2]
            )
            resources.add(writer.writer)
            try writer.start()
            writers.append(writer)
        }
        let sinks = Dictionary(uniqueKeysWithValues: writers.flatMap { $0.audioSinks })
        try await renderAudio(plan, sinks: sinks, progress: progress, baseFraction: 0.08, span: 0.78)
        try Task.checkCancellation()
        for writer in writers { await writer.finish() }
        guard writers.allSatisfy({ $0.writer.status == .completed }) else {
            throw ExportError.publishFailed(stagingURL: stagingURL)
        }
    }

    private static func exportVideoComposition(
        _ plan: ExportPlan,
        outputURL: URL,
        roles: [RecordingTrackRole],
        resources: ExportExecutionResources,
        progress: ExportProgressThrottle
    ) async throws {
        guard let firstClip = plan.clips.first else { throw ExportError.emptySelection }
        let firstSource = try videoSource(for: firstClip, plan: plan)
        let writer = try ExportAssetWriter.videoFile(
            at: outputURL,
            sourceFormatHint: firstSource.formatDescription,
            transform: firstSource.track.preferredTransform,
            sampleRate: plan.outputSpec.audioFormat.sampleRate,
            channelsByRole: Dictionary(uniqueKeysWithValues: roles.map {
                ($0, plan.outputSpec.audioFormat.channelCountByRole[$0] ?? 2)
            })
        )
        resources.add(writer.writer)
        try writer.start()
        try appendVideo(plan, writer: writer, resources: resources, progress: progress)
        try await renderAudio(plan, sinks: writer.audioSinks, progress: progress, baseFraction: 0.42, span: 0.48)
        try Task.checkCancellation()
        await writer.finish()
        guard writer.writer.status == .completed else { throw ExportError.publishFailed(stagingURL: outputURL) }
    }

    private static func renderAudio(
        _ plan: ExportPlan,
        sinks: [RecordingTrackRole: ExportAudioSink],
        progress: ExportProgressThrottle,
        baseFraction: Double,
        span: Double
    ) async throws {
        guard plan.outputSpec.audioFormat.sampleRate == 48_000 else {
            throw ExportError.passthroughUnsupported
        }
        let outputRoles = orderedOutputRoles(plan)
        let totalFrames = max(1, plan.clips.reduce(Int64(0)) { $0 + $1.effectiveRange.sampleCount })
        let gain = pow(10, Double(plan.audioGainDB) / 20)
        var outputFrameOffset: Int64 = 0

        for clip in plan.clips {
            try Task.checkCancellation()
            let source = plan.audioSourcesBySegment[clip.segmentID]
            let cursors = try await audioCursors(
                source: source, segmentIndex: clip.index, sampleRate: plan.outputSpec.audioFormat.sampleRate
            )
            var clipOffset: Int64 = 0
            let chunkLimit: Int64 = 4_096
            while clipOffset < clip.effectiveRange.sampleCount {
                try Task.checkCancellation()
                let frames = Int(min(chunkLimit, clip.effectiveRange.sampleCount - clipOffset))
                let blockStart = clip.effectiveRange.startSample + clipOffset
                let block = SampleRange(startSample: blockStart, sampleCount: Int64(frames))
                for role in outputRoles {
                    guard let sink = sinks[role] else { throw ExportError.passthroughUnsupported }
                    let channels = sink.channelCount
                    var mixed = Array(repeating: Array(repeating: Float.zero, count: frames), count: channels)
                    let matching = audioSources(cursors, for: role)
                    for cursor in matching {
                        guard let overlap = intersection(block, cursor.range) else { continue }
                        let sourceSamples = try cursor.read(overlap)
                        let destinationOffset = Int(overlap.startSample - blockStart)
                        let sourceOffset = 0
                        mix(
                            sourceSamples, sourceChannels: cursor.channelCount,
                            into: &mixed, destinationOffset: destinationOffset,
                            frameCount: Int(overlap.sampleCount), gain: gain
                        )
                        _ = sourceOffset
                    }
                    clamp(&mixed)
                    let pts = outputFrameOffset + clipOffset
                    let buffer = try makePCMBuffer(channels: mixed, sampleRate: sink.sampleRate)
                    try await sink.append(buffer, presentationSample: pts)
                }
                clipOffset += Int64(frames)
                let completed = Double(outputFrameOffset + clipOffset) / Double(totalFrames)
                progress.emit(baseFraction + span * completed, phase: "audio")
            }
            outputFrameOffset += clip.effectiveRange.sampleCount
        }
    }

    private static func audioSources(_ cursors: [ExportAudioCursor], for outputRole: RecordingTrackRole) -> [ExportAudioCursor] {
        if outputRole == .mixed {
            let alreadyMixed = cursors.filter { $0.role == .mixed }
            if !alreadyMixed.isEmpty { return alreadyMixed }
            return cursors.filter { $0.role == .system || $0.role == .microphone }
        }
        return cursors.filter { $0.role == outputRole }
    }

    private static func audioCursors(
        source: ExportAudioSource?,
        segmentIndex: Int,
        sampleRate: Int
    ) async throws -> [ExportAudioCursor] {
        guard let source else { return [] }
        var cursors: [ExportAudioCursor] = []
        var visited: Set<String> = []
        for url in uniqueURLs(source.urls) {
            try Task.checkCancellation()
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path),
                  visited.insert(url.standardizedFileURL.path).inserted
            else { throw ExportError.missingSource }
            let metadata: [ExportAudioTrackMetadata]
            switch source {
            case .checkpointPCM:
                metadata = try checkpointMetadata(url: url, segmentIndex: segmentIndex)
            case .recoveredMedia:
                guard let item = recoveredMetadata(url: url) else { throw ExportError.missingSource }
                metadata = [item]
            case .publishedMedia:
                let record: SegmentPortableRecord
                do { record = try await SegmentPortableMetadata.read(from: url) } catch { throw ExportError.missingSource }
                let named = record.tracks.filter { URL(fileURLWithPath: $0.fileName).lastPathComponent == url.lastPathComponent }
                let tracks = named.isEmpty && record.tracks.count == 1 ? record.tracks : named
                guard !tracks.isEmpty else { throw ExportError.missingSource }
                metadata = tracks.compactMap { track in
                    guard let role = exportRole(track.role) else { return nil }
                    return ExportAudioTrackMetadata(
                        role: role, range: SampleRange(
                            startSample: track.validRange.startSample,
                            sampleCount: track.validRange.sampleCount
                        ), sampleRate: record.sampleRate, channelCount: track.channelCount,
                        primingFrames: track.primingFrames, remainderFrames: track.remainderFrames
                    )
                }
            }
            guard !metadata.isEmpty else { throw ExportError.missingSource }
            for item in metadata {
                cursors.append(try ExportAudioCursor(url: url, metadata: item, outputSampleRate: sampleRate))
            }
        }
        return cursors
    }

    /// Metadata for a recovered file: read from the original media itself.
    ///
    /// Recovered files have no sealed-product portable record, so the range comes
    /// from the file's own frame count. Pipeline media is always 48 kHz, which is
    /// what the export cursor requires.
    private static func recoveredMetadata(url: URL) -> ExportAudioTrackMetadata? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let sampleRate = Int(file.processingFormat.sampleRate.rounded())
        let channelCount = Int(file.processingFormat.channelCount)
        guard sampleRate == 48_000, (1...2).contains(channelCount) else { return nil }
        let role = recoveredRole(url: url)
        return ExportAudioTrackMetadata(
            role: role,
            range: SampleRange(startSample: 0, sampleCount: Int64(file.length)),
            sampleRate: sampleRate,
            channelCount: channelCount,
            primingFrames: 0,
            remainderFrames: 0
        )
    }

    private static func recoveredRole(url: URL) -> RecordingTrackRole {
        let token = url.lastPathComponent.split(separator: "-", maxSplits: 1).first
            .map(String.init)?.lowercased()
        switch token {
        case "system": return .system
        case "mic", "microphone": return .microphone
        default: return .mixed
        }
    }

    private static func checkpointMetadata(url: URL, segmentIndex: Int) throws -> [ExportAudioTrackMetadata] {        let siblings = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("checkpoint-") && $0.pathExtension == "json" }
        for sidecar in siblings {
            guard let data = try? Data(contentsOf: sidecar),
                  let record = try? JSONDecoder().decode(RecordingCheckpointRecord.self, from: data),
                  record.segmentIndex == segmentIndex,
                  let track = record.tracks.first(where: { $0.fileName == url.lastPathComponent }),
                  let role = exportRole(track.role)
            else { continue }
            return [ExportAudioTrackMetadata(
                role: role,
                range: SampleRange(startSample: record.startSample, sampleCount: record.sampleCount),
                sampleRate: track.sampleRate, channelCount: track.channelCount,
                primingFrames: 0, remainderFrames: 0
            ),]
        }
        throw ExportError.missingSource
    }

    private static func appendVideo(
        _ plan: ExportPlan,
        writer: ExportAssetWriter,
        resources: ExportExecutionResources,
        progress: ExportProgressThrottle
    ) throws {
        guard let input = writer.videoInput else { throw ExportError.passthroughUnsupported }
        var outputOffset = CMTime.zero
        let clipCount = max(1, plan.clips.count)
        for (clipIndex, clip) in plan.clips.enumerated() {
            try Task.checkCancellation()
            let source = try videoSource(for: clip, plan: plan)
            guard CFEqual(source.formatDescription, writer.videoFormatDescription) else {
                throw ExportError.incompatibleCodec
            }
            let reader = try AVAssetReader(asset: source.asset)
            reader.timeRange = clip.videoRange?.cmTimeRange ?? .invalid
            let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: nil)
            guard reader.canAdd(output) else { throw ExportError.passthroughUnsupported }
            reader.add(output)
            guard reader.startReading() else { throw ExportError.passthroughUnsupported }
            resources.add(reader)

            var timingShift: CMTime?
            let clipRange = clip.videoRange?.cmTimeRange ?? .invalid
            guard clipRange.isValid, clipRange.duration.isValid else { throw ExportError.missingSource }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let count = CMSampleBufferGetNumSamples(sample)
                guard count == 1 else { throw ExportError.passthroughUnsupported }
                var timing = CMSampleTimingInfo(
                    duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid
                )
                guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
                      timing.presentationTimeStamp.isValid, timing.decodeTimeStamp.isValid
                else { throw ExportError.passthroughUnsupported }
                guard CMTimeCompare(timing.presentationTimeStamp, clipRange.start) >= 0,
                      CMTimeCompare(timing.presentationTimeStamp, CMTimeRangeGetEnd(clipRange)) < 0
                else { continue }
                if timingShift == nil {
                    // Rebase DTS to the current output decode position. PTS keeps
                    // its original composition offset, preserving B-frame order.
                    timingShift = CMTimeSubtract(outputOffset, timing.decodeTimeStamp)
                }
                let shift = timingShift ?? .zero
                let adjusted = CMSampleTimingInfo(
                    duration: timing.duration,
                    presentationTimeStamp: CMTimeAdd(timing.presentationTimeStamp, shift),
                    decodeTimeStamp: CMTimeAdd(timing.decodeTimeStamp, shift)
                )
                var copied: CMSampleBuffer?
                var adjustedTiming = adjusted
                let copyStatus = withUnsafePointer(to: &adjustedTiming) { timingPointer in
                    CMSampleBufferCreateCopyWithNewTiming(
                        allocator: kCFAllocatorDefault, sampleBuffer: sample,
                        sampleTimingEntryCount: 1, sampleTimingArray: timingPointer, sampleBufferOut: &copied
                    )
                }
                guard copyStatus == noErr, let copied,
                      input.isReadyForMoreMediaData || waitUntilReady(input, writer: writer.writer)
                else { throw ExportError.publishFailed(stagingURL: writer.writer.outputURL) }
                guard input.append(copied) else { throw ExportError.publishFailed(stagingURL: writer.writer.outputURL) }
            }
            guard reader.status == .completed, timingShift != nil else {
                throw ExportError.passthroughUnsupported
            }
            resources.remove(reader)
            reader.cancelReading()
            outputOffset = CMTimeAdd(
                outputOffset,
                CMTime(value: clip.effectiveRange.sampleCount, timescale: 48_000)
            )
            progress.emit(0.08 + 0.30 * Double(clipIndex + 1) / Double(clipCount), phase: "video")
        }
    }

    private static func videoSource(for clip: ExportClip, plan: ExportPlan) throws -> ExportVideoSource {
        guard let source = plan.sourceRanges.first(where: { $0.segmentID == clip.segmentID }),
              let url = source.sourceFiles.first(where: { $0.pathExtension.lowercased() == "mp4" }),
              url.isFileURL, FileManager.default.fileExists(atPath: url.path)
        else { throw ExportError.missingSource }
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .video)
        let index = source.videoTrackIndex ?? 0
        guard index >= 0, index < tracks.count else { throw ExportError.passthroughUnsupported }
        let track = tracks[index]
        guard let rawFormat = track.formatDescriptions.first else {
            throw ExportError.passthroughUnsupported
        }
        let format = rawFormat as! CMFormatDescription
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let codec: String
        switch subtype {
        case kCMVideoCodecType_H264: codec = "h264"
        case kCMVideoCodecType_HEVC: codec = "hevc"
        default: throw ExportError.passthroughUnsupported
        }
        guard codec == plan.outputSpec.videoCodec else { throw ExportError.incompatibleCodec }
        return ExportVideoSource(url: url, asset: asset, track: track, formatDescription: format)
    }

    private static func makePCMBuffer(channels: [[Float]], sampleRate: Int) throws -> AVAudioPCMBuffer {
        guard !channels.isEmpty, let frameCount = channels.first?.count, frameCount > 0,
              channels.allSatisfy({ $0.count == frameCount }),
              let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channels.count)
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let storage = buffer.floatChannelData
        else { throw ExportError.passthroughUnsupported }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in channels.indices {
            channels[channel].withUnsafeBufferPointer { source in
                if let base = source.baseAddress { storage[channel].update(from: base, count: frameCount) }
            }
        }
        return buffer
    }

    private static func mix(
        _ source: [[Float]],
        sourceChannels: Int,
        into destination: inout [[Float]],
        destinationOffset: Int,
        frameCount: Int,
        gain: Double
    ) {
        guard sourceChannels > 0, !source.isEmpty else { return }
        for frame in 0..<frameCount {
            for channel in destination.indices {
                let sample: Float
                if sourceChannels == 1 {
                    sample = source[0][frame]
                } else if destination.count == 1 {
                    sample = (source[0][frame] + source[1][frame]) * 0.5
                } else {
                    sample = source[min(channel, sourceChannels - 1)][frame]
                }
                destination[channel][destinationOffset + frame] += Float(Double(sample) * gain)
            }
        }
    }

    private static func clamp(_ channels: inout [[Float]]) {
        for channel in channels.indices {
            for frame in channels[channel].indices {
                let value = channels[channel][frame]
                channels[channel][frame] = value.isFinite ? min(1, max(-1, value)) : 0
            }
        }
    }

    private static func intersection(_ first: SampleRange, _ second: SampleRange) -> SampleRange? {
        let start = max(first.startSample, second.startSample)
        let end = min(first.endSample, second.endSample)
        guard end > start else { return nil }
        return SampleRange(startSample: start, sampleCount: end - start)
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) -> Bool {
        while !input.isReadyForMoreMediaData {
            if Task.isCancelled || writer.status != .writing { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    private static func inspectOutput(
        at url: URL,
        shape: ExportOutputShape,
        fileManager: FileManager
    ) -> (duration: TimeInterval, trackCount: Int) {
        let outputs: [URL]
        switch shape {
        case .singleFile:
            outputs = [url]
        case .directory:
            outputs = (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "m4a" }) ?? []
        }
        var trackCount = 0
        var duration: TimeInterval = 0
        for output in outputs {
            let asset = AVURLAsset(url: output)
            trackCount += asset.tracks(withMediaType: .audio).count
            trackCount += asset.tracks(withMediaType: .video).count
            let seconds = asset.duration.seconds
            if seconds.isFinite { duration = max(duration, seconds) }
        }
        return (duration, trackCount)
    }

    private static func preserveStage(_ url: URL, directory: Bool, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        if directory {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            _ = fileManager.createFile(atPath: url.path, contents: Data())
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func roleToken(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed: "mixed"
        case .system: "system"
        case .microphone: "microphone"
        }
    }

    private static func exportRole(_ value: String) -> RecordingTrackRole? {
        switch value.lowercased() {
        case "mixed": .mixed
        case "system": .system
        case "microphone", "mic": .microphone
        default: nil
        }
    }
}

private struct ExportAudioTrackMetadata {
    let role: RecordingTrackRole
    let range: SampleRange
    let sampleRate: Int
    let channelCount: Int
    let primingFrames: Int
    let remainderFrames: Int
}

private final class ExportAudioCursor {
    let url: URL
    let role: RecordingTrackRole
    let range: SampleRange
    let channelCount: Int
    private let file: AVAudioFile
    private let primingFrames: Int64
    private let sampleRate: Int

    init(url: URL, metadata: ExportAudioTrackMetadata, outputSampleRate: Int) throws {
        guard metadata.range.sampleCount > 0, metadata.sampleRate > 0,
              (1...2).contains(metadata.channelCount), metadata.sampleRate == outputSampleRate
        else { throw ExportError.passthroughUnsupported }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ExportError.missingSource }
        guard Int(file.processingFormat.sampleRate.rounded()) == metadata.sampleRate,
              Int(file.processingFormat.channelCount) == metadata.channelCount
        else { throw ExportError.missingSource }
        let validFrames = AVAudioFramePosition(metadata.range.sampleCount)
        let priming = AVAudioFramePosition(max(0, metadata.primingFrames))
        let remainder = AVAudioFramePosition(max(0, metadata.remainderFrames))
        let canUsePacketPadding = file.length >= priming + validFrames + remainder
        guard file.length >= validFrames || canUsePacketPadding else { throw ExportError.missingSource }
        self.url = url
        role = metadata.role
        range = metadata.range
        channelCount = metadata.channelCount
        self.file = file
        primingFrames = canUsePacketPadding ? Int64(priming) : 0
        sampleRate = metadata.sampleRate
    }

    func read(_ range: SampleRange) throws -> [[Float]] {
        guard range.startSample >= self.range.startSample,
              range.endSample <= self.range.endSample,
              range.sampleCount > 0
        else { throw ExportError.missingSource }
        let offset = range.startSample - self.range.startSample
        let frameOffset = AVAudioFramePosition(offset * Int64(sampleRate) / 48_000)
        let frameCount = AVAudioFrameCount(range.sampleCount * Int64(sampleRate) / 48_000)
        guard frameCount > 0 else { throw ExportError.missingSource }
        file.framePosition = AVAudioFramePosition(primingFrames) + frameOffset
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw ExportError.publishFailed(stagingURL: nil)
        }
        do { try file.read(into: buffer, frameCount: frameCount) } catch { throw ExportError.missingSource }
        guard buffer.frameLength == frameCount else { throw ExportError.missingSource }
        var channels = Array(repeating: Array(repeating: Float.zero, count: Int(frameCount)), count: channelCount)
        if let data = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let stride = buffer.format.isInterleaved ? channelCount : 1
                for frame in 0..<Int(frameCount) {
                    channels[channel][frame] = data[buffer.format.isInterleaved ? 0 : channel][frame * stride + (buffer.format.isInterleaved ? channel : 0)]
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channelCount {
                let stride = buffer.format.isInterleaved ? channelCount : 1
                for frame in 0..<Int(frameCount) {
                    let raw = data[buffer.format.isInterleaved ? 0 : channel][frame * stride + (buffer.format.isInterleaved ? channel : 0)]
                    channels[channel][frame] = Float(raw) / 32_768
                }
            }
        } else {
            throw ExportError.passthroughUnsupported
        }
        return channels
    }
}

private final class ExportAudioSink {
    let input: AVAssetWriterInput
    let sampleRate: Int
    let channelCount: Int
    private var outputFrame: Int64 = 0

    init(input: AVAssetWriterInput, sampleRate: Int, channelCount: Int) {
        self.input = input
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    func append(_ buffer: AVAudioPCMBuffer, presentationSample: Int64) async throws {
        guard presentationSample == outputFrame, Int(buffer.format.sampleRate.rounded()) == sampleRate,
              Int(buffer.format.channelCount) == channelCount
        else { throw ExportError.passthroughUnsupported }
        guard let data = try makeSampleBuffer(from: buffer, presentationSample: presentationSample) else {
            throw ExportError.passthroughUnsupported
        }
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            await Task.yield()
        }
        guard input.append(data) else { throw ExportError.publishFailed(stagingURL: nil) }
        outputFrame += Int64(buffer.frameLength)
    }

    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, presentationSample: Int64) throws -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: presentationSample, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription,
            sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        )
        guard dataStatus == noErr, CMSampleBufferSetDataReady(sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}

private final class ExportAssetWriter {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput?
    let videoFormatDescription: CMFormatDescription?
    let audioSinks: [RecordingTrackRole: ExportAudioSink]
    private let inputs: [AVAssetWriterInput]

    private init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput?,
        videoFormatDescription: CMFormatDescription?,
        audioSinks: [RecordingTrackRole: ExportAudioSink],
        inputs: [AVAssetWriterInput]
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.videoFormatDescription = videoFormatDescription
        self.audioSinks = audioSinks
        self.inputs = inputs
    }

    static func audioFile(
        at url: URL,
        sampleRate: Int,
        channelsByRole: [RecordingTrackRole: Int]
    ) throws -> ExportAssetWriter {
        try make(at: url, type: .m4a, sourceVideo: nil, transform: .identity,
                 sampleRate: sampleRate, channelsByRole: channelsByRole)
    }

    static func videoFile(
        at url: URL,
        sourceFormatHint: CMFormatDescription,
        transform: CGAffineTransform,
        sampleRate: Int,
        channelsByRole: [RecordingTrackRole: Int]
    ) throws -> ExportAssetWriter {
        try make(at: url, type: .mp4, sourceVideo: sourceFormatHint, transform: transform,
                 sampleRate: sampleRate, channelsByRole: channelsByRole)
    }

    private static func make(
        at url: URL,
        type: AVFileType,
        sourceVideo: CMFormatDescription?,
        transform: CGAffineTransform,
        sampleRate: Int,
        channelsByRole: [RecordingTrackRole: Int]
    ) throws -> ExportAssetWriter {
        guard (8_000...192_000).contains(sampleRate), !channelsByRole.isEmpty else {
            throw ExportError.passthroughUnsupported
        }
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: type) } catch { throw ExportError.publishFailed(stagingURL: url) }
        var inputs: [AVAssetWriterInput] = []
        var videoInput: AVAssetWriterInput?
        if let sourceVideo {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: sourceVideo)
            input.expectsMediaDataInRealTime = false
            input.transform = transform
            guard writer.canAdd(input) else { throw ExportError.passthroughUnsupported }
            writer.add(input)
            inputs.append(input)
            videoInput = input
        }
        var audioSinks: [RecordingTrackRole: ExportAudioSink] = [:]
        for (role, channels) in channelsByRole.sorted(by: { roleIndex($0.key) < roleIndex($1.key) }) {
            guard (1...2).contains(channels) else { throw ExportError.passthroughUnsupported }
            let bitrate = channels == 1 ? 96_000 : 160_000
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.passthroughUnsupported }
            writer.add(input)
            inputs.append(input)
            audioSinks[role] = ExportAudioSink(input: input, sampleRate: sampleRate, channelCount: channels)
        }
        return ExportAssetWriter(
            writer: writer, videoInput: videoInput, videoFormatDescription: sourceVideo,
            audioSinks: audioSinks, inputs: inputs
        )
    }

    func start() throws {
        guard writer.startWriting() else { throw ExportError.publishFailed(stagingURL: writer.outputURL) }
        writer.startSession(atSourceTime: .zero)
    }

    func finish() async {
        for input in inputs { input.markAsFinished() }
        await writer.finishWriting()
    }

    private static func roleIndex(_ role: RecordingTrackRole) -> Int {
        switch role {
        case .mixed: 0
        case .system: 1
        case .microphone: 2
        }
    }
}

private final class ExportExecutionResources {
    private var readers: [AVAssetReader] = []
    private var writers: [AVAssetWriter] = []

    func add(_ reader: AVAssetReader) { readers.append(reader) }
    func remove(_ reader: AVAssetReader) { readers.removeAll { $0 === reader } }
    func add(_ writer: AVAssetWriter) { writers.append(writer) }

    func cancel() {
        for reader in readers where reader.status == .reading { reader.cancelReading() }
        for writer in writers where writer.status == .writing || writer.status == .unknown {
            writer.cancelWriting()
        }
    }
}

private struct ExportVideoSource {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let formatDescription: CMFormatDescription
}

private final class ExportProgressThrottle {
    private let lock = NSLock()
    private let callback: @Sendable (ExportProgress) -> Void
    private var lastEmitNanos: UInt64 = 0

    init(_ callback: @escaping @Sendable (ExportProgress) -> Void) {
        self.callback = callback
    }

    func emit(_ fraction: Double, phase: String, force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        _ = force
        guard lastEmitNanos == 0 || now - lastEmitNanos >= 250_000_000 else { return }
        lastEmitNanos = now
        callback(ExportProgress(fraction: min(1, max(0, fraction)), phase: phase))
    }
}

private extension SampleRange {
    var endSample: Int64 { startSample + sampleCount }
}
