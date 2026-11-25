import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

private struct AudioMixRequest {
    let source: [[Float]]
    let sourceChannels: Int
    let destinationOffset: Int
    let frameCount: Int
    let gain: Double
}

private struct VideoSampleContext {
    let input: AVAssetWriterInput
    let writer: ExportAssetWriter
    let clipRange: CMTimeRange
    let outputOffset: CMTime
}

extension RecordingExportWorker {
    static func revalidateActualMedia(_ plan: ExportPlan) async throws -> ExportPlan {
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

    static func outputRequest(for plan: ExportPlan) throws -> RecordingOutputRequest {
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

    static func orderedOutputRoles(_ plan: ExportPlan) -> [RecordingTrackRole] {
        RecordingCheckpointWriter.roleOrder.filter { plan.trackMap[$0] != nil }
    }

    static func exportAudioFile(
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

    static func exportSeparatedAudioDirectory(
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

    static func exportVideoComposition(
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

    static func renderAudio(
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
                            AudioMixRequest(
                                source: sourceSamples,
                                sourceChannels: cursor.channelCount,
                                destinationOffset: destinationOffset,
                                frameCount: Int(overlap.sampleCount),
                                gain: gain
                            ),
                            into: &mixed
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

    static func audioSources(
        _ cursors: [ExportAudioCursor],
        for outputRole: RecordingTrackRole
    ) -> [ExportAudioCursor] {
        if outputRole == .mixed {
            let alreadyMixed = cursors.filter { $0.role == .mixed }
            if !alreadyMixed.isEmpty { return alreadyMixed }
            return cursors.filter { $0.role == .system || $0.role == .microphone }
        }
        return cursors.filter { $0.role == outputRole }
    }

    static func audioCursors(
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
                do {
                    record = try await SegmentPortableMetadata.read(from: url)
                } catch {
                    throw ExportError.missingSource
                }
                let named = record.tracks.filter {
                    URL(fileURLWithPath: $0.fileName).lastPathComponent == url.lastPathComponent
                }
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
    static func recoveredMetadata(url: URL) -> ExportAudioTrackMetadata? {
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

    static func recoveredRole(url: URL) -> RecordingTrackRole {
        let token = url.lastPathComponent.split(separator: "-", maxSplits: 1).first
            .map(String.init)?.lowercased()
        switch token {
        case "system": return .system
        case "mic", "microphone": return .microphone
        default: return .mixed
        }
    }

    static func checkpointMetadata(
        url: URL,
        segmentIndex: Int
    ) throws -> [ExportAudioTrackMetadata] {
        let siblings = try FileManager.default.contentsOfDirectory(
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

    static func appendVideo(
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
            let sampleContext = VideoSampleContext(
                input: input,
                writer: writer,
                clipRange: clipRange,
                outputOffset: outputOffset
            )
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                _ = try appendVideoSample(
                    sample,
                    context: sampleContext,
                    timingShift: &timingShift
                )
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

    private static func appendVideoSample(
        _ sample: CMSampleBuffer,
        context: VideoSampleContext,
        timingShift: inout CMTime?
    ) throws -> Bool {
        let count = CMSampleBufferGetNumSamples(sample)
        guard count == 1 else { throw ExportError.passthroughUnsupported }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid
        )
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
              timing.presentationTimeStamp.isValid, timing.decodeTimeStamp.isValid
        else { throw ExportError.passthroughUnsupported }
        guard CMTimeCompare(timing.presentationTimeStamp, context.clipRange.start) >= 0,
              CMTimeCompare(timing.presentationTimeStamp, CMTimeRangeGetEnd(context.clipRange)) < 0
        else { return false }
        if timingShift == nil {
            // Rebase DTS to the current output decode position. PTS keeps
            // its original composition offset, preserving B-frame order.
            timingShift = CMTimeSubtract(context.outputOffset, timing.decodeTimeStamp)
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
              context.input.isReadyForMoreMediaData
                  || waitUntilReady(context.input, writer: context.writer.writer)
        else { throw ExportError.publishFailed(stagingURL: context.writer.writer.outputURL) }
        guard context.input.append(copied) else {
            throw ExportError.publishFailed(stagingURL: context.writer.writer.outputURL)
        }
        return true
    }

    static func videoSource(for clip: ExportClip, plan: ExportPlan) throws -> ExportVideoSource {
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
        // `formatDescriptions` is documented as [CMFormatDescription]; the
        // Objective-C bridge exposes it as [Any].
        // swiftlint:disable:next force_cast
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

    static func makePCMBuffer(channels: [[Float]], sampleRate: Int) throws -> AVAudioPCMBuffer {
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
        _ request: AudioMixRequest,
        into destination: inout [[Float]]
    ) {
        let source = request.source
        let sourceChannels = request.sourceChannels
        let destinationOffset = request.destinationOffset
        let frameCount = request.frameCount
        let gain = request.gain
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

    static func clamp(_ channels: inout [[Float]]) {
        for channel in channels.indices {
            for frame in channels[channel].indices {
                let value = channels[channel][frame]
                channels[channel][frame] = value.isFinite ? min(1, max(-1, value)) : 0
            }
        }
    }

    static func intersection(_ first: SampleRange, _ second: SampleRange) -> SampleRange? {
        let start = max(first.startSample, second.startSample)
        let end = min(first.endSample, second.endSample)
        guard end > start else { return nil }
        return SampleRange(startSample: start, sampleCount: end - start)
    }

    static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) -> Bool {
        while !input.isReadyForMoreMediaData {
            if Task.isCancelled || writer.status != .writing { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    static func inspectOutput(
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

    static func preserveStage(_ url: URL, directory: Bool, fileManager: FileManager) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        if directory {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            _ = fileManager.createFile(atPath: url.path, contents: Data())
        }
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func roleToken(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed: "mixed"
        case .system: "system"
        case .microphone: "microphone"
        }
    }

    static func exportRole(_ value: String) -> RecordingTrackRole? {
        switch value.lowercased() {
        case "mixed": .mixed
        case "system": .system
        case "microphone", "mic": .microphone
        default: nil
        }
    }
}

private extension SampleRange {
    var endSample: Int64 { startSample + sampleCount }
}
