import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Failures raised while joining closed screen chunks and sealing audio tracks.
public enum ScreenSegmentSealError: Error, Equatable, Sendable {
    case invalidContext
    case invalidCheckpoints
    case videoTrackUnavailable
    case writerFailed
    case audioFormatMismatch
    case audioReadFailed
    case rangeMismatch
}

/// Seals closed video chunks into one MP4 while streaming AAC audio into that same file.
public actor ScreenSegmentSealService {
    private let fileManager: FileManager
    private let publicationHooks: [any SegmentPublicationHooking]
    private var isSealing = false

    /// Creates a screen-specific sealer; publication hooks are fixed at construction.
    public init(
        fileManager: FileManager = .default,
        publicationHooks: [any SegmentPublicationHooking] = []
    ) {
        self.fileManager = fileManager
        self.publicationHooks = publicationHooks
    }

    /// Joins verified compressed video chunks and adds one continuous AAC input per active role.
    public func seal(
        _ checkpoints: [ScreenCheckpointRecord],
        audio: RecordingSegmentCheckpointBundle?,
        segmentID: UUID,
        context: RecordingSealContext
    ) async throws -> SealedSegment {
        guard !isSealing else { throw RecordingSealError.sealInProgress }
        isSealing = true
        defer { isSealing = false }

        let ordered = checkpoints.sorted { $0.chunkIndex < $1.chunkIndex }
        guard context.kind == .screen,
              context.destinationDirectory.isFileURL,
              fileManager.fileExists(atPath: context.destinationDirectory.path),
              !context.outputStem.isEmpty,
              let first = ordered.first,
              ordered.allSatisfy({ $0.segmentIndex == first.segmentIndex }),
              Set(ordered.map(\.chunkIndex)).count == ordered.count,
              ordered.allSatisfy({ $0.videoRange.sampleCount > 0 }),
              zip(ordered, ordered.dropFirst()).allSatisfy({
                  $0.videoRange.startSample + $0.videoRange.sampleCount == $1.videoRange.startSample
              })
        else { throw ScreenSegmentSealError.invalidCheckpoints }
        guard context.sampleRate == 48_000 else { throw ScreenSegmentSealError.invalidContext }

        let startSample = first.videoRange.startSample
        guard let last = ordered.last else { throw ScreenSegmentSealError.invalidCheckpoints }
        let endSample = last.videoRange.startSample + last.videoRange.sampleCount
        guard endSample > startSample,
              endSample - startSample <= 3_540 * 48_000
        else { throw ScreenSegmentSealError.rangeMismatch }
        if let audio, audio.checkpoints.segmentIndex != first.segmentIndex {
            throw ScreenSegmentSealError.rangeMismatch
        }

        let request = try RecordingOutputRequest(
            destinationDirectory: context.destinationDirectory,
            stem: context.outputStem,
            segmentIndex: first.segmentIndex,
            shape: .singleFile(fileExtension: "mp4")
        )
        let transaction = try RecordingOutputTransaction(request: request, fileManager: fileManager)
        try transaction.prepareForWriting()

        let firstVideo = try await videoTrack(for: ordered[0].videoURL)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: transaction.partialURL, fileType: .mp4) }
        catch { throw ScreenSegmentSealError.writerFailed }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: firstVideo.format
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ScreenSegmentSealError.videoTrackUnavailable }
        writer.add(videoInput)

        let roleURLs = Self.audioURLs(audio)
        var audioSinks: [RecordingTrackRole: AudioAACStreamSink] = [:]
        var trackMap: [RecordingTrackRole: Int] = [:]
        for (index, role) in roleURLs.keys.sorted(by: { Self.roleOrder($0) < Self.roleOrder($1) }).enumerated() {
            guard let urls = roleURLs[role], let firstURL = urls.first else { continue }
        let format = try audioFormat(at: firstURL)
            let sink = try AudioAACStreamSink(
                writer: writer,
                role: role,
                sampleRate: format.sampleRate,
                channelCount: format.channelCount,
                bitRate: context.bitRate ?? (format.channelCount == 1 ? 96_000 : 160_000)
            )
            audioSinks[role] = sink
            trackMap[role] = index + 1
        }

        guard writer.startWriting() else { throw ScreenSegmentSealError.writerFailed }
        var mediaOrigin: CMTime?
        for checkpoint in ordered {
            try await appendVideo(
                from: checkpoint.videoURL,
                writer: writer,
                input: videoInput,
                mediaOrigin: &mediaOrigin
            )
        }
        guard let mediaOrigin else { throw ScreenSegmentSealError.videoTrackUnavailable }

        for (role, sink) in audioSinks {
            guard let urls = roleURLs[role] else { continue }
            try await appendAudio(
                urls: urls,
                role: role,
                sink: sink,
                segmentStartSample: startSample,
                segmentEndSample: endSample,
                mediaOrigin: mediaOrigin
            )
            try sink.finish()
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed,
              RecordingLedgerFileSystem.isRegularFile(transaction.partialURL)
        else { throw ScreenSegmentSealError.writerFailed }
        try transaction.markWriterFinished()
        try RecordingLedgerFileSystem.syncFile(transaction.partialURL)
        try RecordingLedgerFileSystem.syncDirectory(transaction.partialURL.deletingLastPathComponent())

        let hash = try RecordingLedgerFileSystem.sha256(of: transaction.partialURL)
        let hashes = [transaction.finalURL.lastPathComponent: hash]
        let coverage = audio?.coverage ?? RecordingSegmentCoverage(
            segmentIndex: first.segmentIndex,
            segmentStartSample: startSample,
            segmentEndSample: endSample,
            tracks: []
        )
        let stagedFiles = Dictionary(uniqueKeysWithValues: trackMap.keys.map { ($0, transaction.partialURL) })
        let candidate = SegmentPublicationCandidate(
            segmentID: segmentID,
            segmentIndex: first.segmentIndex,
            stagingURL: transaction.partialURL,
            reservedFinalURL: transaction.finalURL,
            isDirectory: false,
            stagedFileURLs: stagedFiles,
            contentHashes: hashes,
            manifestURL: nil,
            effectiveRange: RecordingSampleRange(startSample: startSample, sampleCount: endSample - startSample),
            coverage: coverage
        )
        for hook in publicationHooks {
            try await hook.beforePublish(candidate)
        }
        let publishedURL = try transaction.publish()
        guard publishedURL == transaction.finalURL else { throw RecordingSealError.publishedURLMismatch }

        return SealedSegment(
            segmentID: segmentID,
            index: first.segmentIndex,
            files: Dictionary(uniqueKeysWithValues: trackMap.keys.map { ($0, publishedURL) }),
            manifestURL: nil,
            effectiveRange: SampleRange(startSample: startSample, sampleCount: endSample - startSample),
            trackMap: trackMap,
            videoURL: publishedURL,
            videoTrackIndex: 0
        )
    }

    private func videoTrack(for url: URL) async throws -> (track: AVAssetTrack, format: CMFormatDescription) {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .video) }
        catch { throw ScreenSegmentSealError.videoTrackUnavailable }
        guard let track = tracks.first else { throw ScreenSegmentSealError.videoTrackUnavailable }
        let descriptions: [CMFormatDescription]
        do { descriptions = try await track.load(.formatDescriptions) }
        catch { throw ScreenSegmentSealError.videoTrackUnavailable }
        guard let format = descriptions.first else { throw ScreenSegmentSealError.videoTrackUnavailable }
        return (track, format)
    }

    private func appendVideo(
        from url: URL,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        mediaOrigin: inout CMTime?
    ) async throws {
        let source = try await videoTrack(for: url)
        let asset = AVURLAsset(url: url)
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw ScreenSegmentSealError.videoTrackUnavailable }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: nil)
        guard reader.canAdd(output) else { throw ScreenSegmentSealError.videoTrackUnavailable }
        reader.add(output)
        guard reader.startReading() else { throw ScreenSegmentSealError.videoTrackUnavailable }

        var sawSample = false
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if mediaOrigin == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isValid, pts.isNumeric else { throw ScreenSegmentSealError.videoTrackUnavailable }
                mediaOrigin = pts
                writer.startSession(atSourceTime: pts)
            }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw ScreenSegmentSealError.writerFailed }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.append(sample) else { throw ScreenSegmentSealError.writerFailed }
            sawSample = true
        }
        guard reader.status == .completed, sawSample else {
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
    }

    private func appendAudio(
        urls: [URL],
        role: RecordingTrackRole,
        sink: AudioAACStreamSink,
        segmentStartSample: Int64,
        segmentEndSample: Int64,
        mediaOrigin: CMTime
    ) async throws {
        var cursor = segmentStartSample
        guard let firstURL = urls.first else { throw ScreenSegmentSealError.audioReadFailed }
        let channels = try audioFormat(at: firstURL).channelCount
        let ordered = try urls.map { url -> (URL, CheckpointCommit) in
            guard let commit = try audioCommit(for: url) else { throw ScreenSegmentSealError.rangeMismatch }
            return (url, commit)
        }.sorted { $0.1.range.startSample < $1.1.range.startSample }
        for (url, commit) in ordered {
            guard commit.range.startSample >= cursor,
                  commit.range.startSample + commit.range.sampleCount <= segmentEndSample
            else { throw ScreenSegmentSealError.rangeMismatch }
            if commit.range.startSample > cursor {
                try await appendSilence(
                    role: role,
                    start: cursor,
                    count: commit.range.startSample - cursor,
                    channelCount: channels,
                    sink: sink,
                    segmentStartSample: segmentStartSample,
                    mediaOrigin: mediaOrigin
                )
            }
            try await appendCAF(
                at: url,
                role: role,
                startSample: commit.range.startSample,
                expectedFrames: commit.range.sampleCount,
                sink: sink,
                segmentStartSample: segmentStartSample,
                mediaOrigin: mediaOrigin
            )
            cursor = commit.range.startSample + commit.range.sampleCount
        }
        if cursor < segmentEndSample {
            try await appendSilence(
                role: role,
                start: cursor,
                count: segmentEndSample - cursor,
                channelCount: channels,
                sink: sink,
                segmentStartSample: segmentStartSample,
                mediaOrigin: mediaOrigin
            )
        }
    }

    private func appendCAF(
        at url: URL,
        role: RecordingTrackRole,
        startSample: Int64,
        expectedFrames: Int64,
        sink: AudioAACStreamSink,
        segmentStartSample: Int64,
        mediaOrigin: CMTime
    ) async throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw ScreenSegmentSealError.audioReadFailed }
        let format = file.processingFormat
        guard Int(format.sampleRate.rounded()) == 48_000,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              Int(format.channelCount) > 0,
              file.length >= expectedFrames
        else { throw ScreenSegmentSealError.audioFormatMismatch }

        var remaining = expectedFrames
        var sample = startSample
        while remaining > 0 {
            let count = Int(min(4_096, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw ScreenSegmentSealError.audioReadFailed
            }
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(count)) }
            catch { throw ScreenSegmentSealError.audioReadFailed }
            guard Int(buffer.frameLength) == count, let channelData = buffer.floatChannelData else {
                throw ScreenSegmentSealError.audioReadFailed
            }
            let channels = (0..<Int(format.channelCount)).map { channel in
                Array(UnsafeBufferPointer(start: channelData[channel], count: count))
            }
            let block = AudioPCMBlock(
                role: role,
                range: SampleRange(startSample: sample, sampleCount: Int64(count)),
                sampleRate: 48_000,
                channelCount: channels.count,
                frameCount: count,
                hostTime: 0,
                channels: channels,
                isSilence: channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
            )
            try await sink.append(block, segmentStartSample: segmentStartSample, mediaOrigin: mediaOrigin)
            sample += Int64(count)
            remaining -= Int64(count)
        }
    }

    private func appendSilence(
        role: RecordingTrackRole,
        start: Int64,
        count: Int64,
        channelCount: Int,
        sink: AudioAACStreamSink,
        segmentStartSample: Int64,
        mediaOrigin: CMTime
    ) async throws {
        var cursor = start
        var remaining = count
        while remaining > 0 {
            let frames = Int(min(4_096, remaining))
            let block = AudioPCMBlock(
                role: role,
                range: SampleRange(startSample: cursor, sampleCount: Int64(frames)),
                sampleRate: 48_000,
                channelCount: channelCount,
                frameCount: frames,
                hostTime: 0,
                channels: Array(repeating: [Float](repeating: 0, count: frames), count: channelCount),
                isSilence: true
            )
            try await sink.append(block, segmentStartSample: segmentStartSample, mediaOrigin: mediaOrigin)
            cursor += Int64(frames)
            remaining -= Int64(frames)
        }
    }

    private func audioFormat(at url: URL) throws -> (sampleRate: Int, channelCount: Int) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw ScreenSegmentSealError.audioReadFailed }
        let format = file.processingFormat
        guard Int(format.sampleRate.rounded()) == 48_000,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              (1...2).contains(Int(format.channelCount))
        else { throw ScreenSegmentSealError.audioFormatMismatch }
        return (48_000, Int(format.channelCount))
    }

    private func audioCommit(for url: URL) throws -> CheckpointCommit? {
        // Checkpoint IDs are in the sidecar contents, so locate the owning record by directory entries.
        let directory = url.deletingLastPathComponent()
        let sidecars = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for candidate in sidecars where candidate.lastPathComponent.hasPrefix("checkpoint-") {
            guard let data = try? Data(contentsOf: candidate),
                  let record = try? RecordingCheckpointSidecar.decode(data, path: candidate.path),
                  record.tracks.contains(where: { $0.fileName == url.lastPathComponent })
            else { continue }
            let roleURLs = Dictionary(uniqueKeysWithValues: record.tracks.compactMap { track -> (RecordingTrackRole, URL)? in
                guard let role = Self.role(for: track.role) else { return nil }
                return (role, directory.appendingPathComponent(track.fileName))
            })
            return CheckpointCommit(
                checkpointID: record.checkpointID,
                segmentIndex: record.segmentIndex,
                range: SampleRange(startSample: record.startSample, sampleCount: record.sampleCount),
                trackURLs: roleURLs,
                committedAt: record.committedAt
            )
        }
        return nil
    }

    private static func audioURLs(_ bundle: RecordingSegmentCheckpointBundle?) -> [RecordingTrackRole: [URL]] {
        guard let bundle else { return [:] }
        var result: [RecordingTrackRole: [URL]] = [:]
        for commit in bundle.checkpoints.checkpoints {
            for (role, url) in commit.trackURLs {
                result[role, default: []].append(url)
            }
        }
        return result
    }

    private static func roleOrder(_ role: RecordingTrackRole) -> Int {
        switch role {
        case .mixed: 0
        case .system: 1
        case .microphone: 2
        }
    }

    private static func role(for string: String) -> RecordingTrackRole? {
        switch string {
        case "mixed": .mixed
        case "system": .system
        case "microphone": .microphone
        default: nil
        }
    }
}
