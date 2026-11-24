import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import SharedKit

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

struct VideoTrackHandle {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let format: CMFormatDescription
}

/// Seals closed video chunks into one MP4 while streaming AAC audio into that same file.
public actor ScreenSegmentSealService {
    let fileManager: FileManager
    private let publicationHooks: [any SegmentPublicationHooking]
    private var isSealing = false
    let logger = Logger(subsystem: "com.snapglass", category: "screen.seal")

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

        let range = try validateSealInputs(checkpoints, audio: audio, context: context)
        let ordered = range.ordered
        let first = range.first
        let startSample = range.startSample
        let endSample = range.endSample

        let request = try RecordingOutputRequest(
            destinationDirectory: context.destinationDirectory,
            stem: context.outputStem,
            segmentIndex: first.segmentIndex,
            shape: .singleFile(fileExtension: "mp4")
        )
        let transaction = try RecordingOutputTransaction(request: request, fileManager: fileManager)
        try transaction.prepareForWriting()

        let firstVideo = try await videoTrack(for: ordered[0].videoURL)
        logger.info("screen.seal chunks=\(ordered.count) videoTrackReady")
        let writerContext = try makeWriter(transaction: transaction, firstVideo: firstVideo)
        let writer = writerContext.writer
        let videoInput = writerContext.videoInput

        let audioSinks = try makeAudioSinks(writer: writer, audio: audio, context: context)

        guard writer.startWriting() else { throw ScreenSegmentSealError.writerFailed }
        logger.info("screen.seal writer started")
        let mediaOrigin = try await firstVideoMediaOrigin(for: ordered[0].videoURL)
        writer.startSession(atSourceTime: mediaOrigin)
        logger.info("screen.seal media origin=\(CMTimeGetSeconds(mediaOrigin))")

        let audioTask: Task<Void, any Error>? = audioSinks.sinks.isEmpty
            ? nil
            : Task { [self] in
                try await appendAudioTracks(
                    roleURLs: audioSinks.roleURLs,
                    audioSinks: audioSinks.sinks,
                    segmentStartSample: startSample,
                    segmentEndSample: endSample,
                    mediaOrigin: mediaOrigin
                )
            }
        do {
            for checkpoint in ordered {
                try await appendVideo(
                    from: checkpoint.videoURL,
                    writer: writer,
                    input: videoInput
                )
            }
            try await audioTask?.value
        } catch {
            audioTask?.cancel()
            _ = try? await audioTask?.value
            throw error
        }
        try await finishWriting(writer: writer, videoInput: videoInput, transaction: transaction)

        let coverage = Self.publicationCoverage(
            audio?.coverage, segmentIndex: first.segmentIndex,
            segmentStartSample: startSample, segmentEndSample: endSample
        )
        return try await publishSealedSegment(
            SealPublication(
                transaction: transaction,
                segmentID: segmentID,
                segmentIndex: first.segmentIndex,
                startSample: startSample,
                endSample: endSample,
                trackMap: audioSinks.trackMap,
                coverage: coverage,
                publicationHooks: publicationHooks
            )
        )
    }

    private struct SealWriter {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
    }

    private func makeWriter(
        transaction: RecordingOutputTransaction,
        firstVideo: VideoTrackHandle
    ) throws -> SealWriter {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: transaction.partialURL, fileType: .mp4)
        } catch {
            throw ScreenSegmentSealError.writerFailed
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: firstVideo.format
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw ScreenSegmentSealError.videoTrackUnavailable }
        writer.add(videoInput)
        return SealWriter(writer: writer, videoInput: videoInput)
    }

    private func finishWriting(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        transaction: RecordingOutputTransaction
    ) async throws {
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed,
              RecordingLedgerFileSystem.isRegularFile(transaction.partialURL)
        else { throw ScreenSegmentSealError.writerFailed }
        try transaction.markWriterFinished()
        try RecordingLedgerFileSystem.syncFile(transaction.partialURL)
        try RecordingLedgerFileSystem.syncDirectory(transaction.partialURL.deletingLastPathComponent())
    }

    private struct SealRange {
        let ordered: [ScreenCheckpointRecord]
        let first: ScreenCheckpointRecord
        let startSample: Int64
        let endSample: Int64
    }

    private func validateSealInputs(
        _ checkpoints: [ScreenCheckpointRecord],
        audio: RecordingSegmentCheckpointBundle?,
        context: RecordingSealContext
    ) throws -> SealRange {
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
        return SealRange(ordered: ordered, first: first, startSample: startSample, endSample: endSample)
    }

    private struct SealAudioSinks {
        let roleURLs: [RecordingTrackRole: [URL]]
        let sinks: [RecordingTrackRole: AudioAACStreamSink]
        let trackMap: [RecordingTrackRole: Int]
    }

    private func makeAudioSinks(
        writer: AVAssetWriter,
        audio: RecordingSegmentCheckpointBundle?,
        context: RecordingSealContext
    ) throws -> SealAudioSinks {
        let roleURLs = Self.audioURLs(audio)
        var sinks: [RecordingTrackRole: AudioAACStreamSink] = [:]
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
            sinks[role] = sink
            trackMap[role] = index + 1
        }
        return SealAudioSinks(roleURLs: roleURLs, sinks: sinks, trackMap: trackMap)
    }

    private struct SealPublication {
        let transaction: RecordingOutputTransaction
        let segmentID: UUID
        let segmentIndex: Int
        let startSample: Int64
        let endSample: Int64
        let trackMap: [RecordingTrackRole: Int]
        let coverage: RecordingSegmentCoverage
        let publicationHooks: [any SegmentPublicationHooking]
    }

    private func publishSealedSegment(_ publication: SealPublication) async throws -> SealedSegment {
        let hash = try RecordingLedgerFileSystem.sha256(of: publication.transaction.partialURL)
        let hashes = [publication.transaction.finalURL.lastPathComponent: hash]
        let stagedFiles = Dictionary(uniqueKeysWithValues: publication.trackMap.keys.map {
            ($0, publication.transaction.partialURL)
        })
        let candidate = SegmentPublicationCandidate(
            segmentID: publication.segmentID,
            segmentIndex: publication.segmentIndex,
            stagingURL: publication.transaction.partialURL,
            reservedFinalURL: publication.transaction.finalURL,
            isDirectory: false,
            stagedFileURLs: stagedFiles,
            contentHashes: hashes,
            manifestURL: nil,
            effectiveRange: RecordingSampleRange(
                startSample: publication.startSample,
                sampleCount: publication.endSample - publication.startSample
            ),
            coverage: publication.coverage
        )
        for hook in publication.publicationHooks {
            try await hook.beforePublish(candidate)
        }
        let publishedURL = try publication.transaction.publish()
        guard publishedURL == publication.transaction.finalURL else {
            throw RecordingSealError.publishedURLMismatch
        }
        return SealedSegment(
            segmentID: publication.segmentID,
            index: publication.segmentIndex,
            files: Dictionary(uniqueKeysWithValues: publication.trackMap.keys.map { ($0, publishedURL) }),
            manifestURL: nil,
            effectiveRange: SampleRange(
                startSample: publication.startSample,
                sampleCount: publication.endSample - publication.startSample
            ),
            trackMap: publication.trackMap,
            videoURL: publishedURL,
            videoTrackIndex: 0
        )
    }


    func videoTrack(
        for url: URL
    ) async throws -> VideoTrackHandle {
        // The track must belong to the same AVURLAsset instance the reader is
        // created from: a track from another instance makes `canAdd` fail.
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .video) } catch {
            logger.error("screen.seal loadTracks failed: \(String(describing: error))")
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        guard let track = tracks.first else {
            logger.error("screen.seal chunk has no video track")
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        let descriptions: [CMFormatDescription]
        do { descriptions = try await track.load(.formatDescriptions) } catch {
            logger.error("screen.seal format descriptions failed: \(String(describing: error))")
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        guard let format = descriptions.first else {
            logger.error("screen.seal chunk has no video format")
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        return VideoTrackHandle(asset: asset, track: track, format: format)
    }

    /// Reads the first video sample's presentation time from a chunk.
    ///
    /// The seal writer needs one session origin for both the video and audio
    /// inputs, so the origin is resolved before either input starts.
    ///
    /// - Parameter url: A closed chunk MP4.
    /// - Returns: The first sample's presentation timestamp.
    /// - Throws: ``ScreenSegmentSealError/videoTrackUnavailable`` when no sample is readable.
    private func firstVideoMediaOrigin(for url: URL) async throws -> CMTime {
        let source = try await videoTrack(for: url)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: nil)
        guard reader.canAdd(output) else { throw ScreenSegmentSealError.videoTrackUnavailable }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer() else {
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, pts.isNumeric else {
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        return pts
    }

    /// Feeds every prepared audio track while the video input is being appended.
    ///
    /// - Parameters:
    ///   - roleURLs: Audio checkpoint files keyed by role.
    ///   - audioSinks: One AAC input per active role, already added to the writer.
    ///   - segmentStartSample: Session sample of the segment start.
    ///   - segmentEndSample: Exclusive session sample of the segment end.
    ///   - mediaOrigin: Output time of the segment's first media sample.

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

    static func role(for string: String) -> RecordingTrackRole? {
        switch string {
        case "mixed": .mixed
        case "system": .system
        case "microphone": .microphone
        default: nil
        }
    }

    /// Returns coverage that describes the sealed output, not the narrower audio bundle.
    ///
    /// The sealer pads a short audio tail with silence up to the last video sample.
    /// The audio bundle's own coverage may end a few milliseconds earlier: the source
    /// can stop delivering samples before the final video frame is closed. Publishing
    /// that narrower range makes the ledger reject the intent, because its coverage
    /// must match the video's effective range. Missing ranges are kept (they are the
    /// honest audio-loss signal) but clamped to the sealed segment.
    private static func publicationCoverage(
        _ audio: RecordingSegmentCoverage?,
        segmentIndex: Int,
        segmentStartSample: Int64,
        segmentEndSample: Int64
    ) -> RecordingSegmentCoverage {
        guard let audio else {
            return RecordingSegmentCoverage(
                segmentIndex: segmentIndex,
                segmentStartSample: segmentStartSample,
                segmentEndSample: segmentEndSample,
                tracks: []
            )
        }
        let tracks = audio.tracks.map { track in
            var missing = track.missingRanges.compactMap { range -> RecordingSampleRange? in
                let start = max(range.startSample, segmentStartSample)
                let end = min(range.endSample, segmentEndSample)
                guard end > start else { return nil }
                return RecordingSampleRange(startSample: start, sampleCount: end - start)
            }
            // The audio bundle stops at the audio source's last sample, while the
            // sealed segment now runs to the video end. Record that padded tail (and
            // any padded head) as missing so the coverage stays honest.
            if let first = track.firstSample, first > segmentStartSample {
                missing.append(
                    RecordingSampleRange(
                        startSample: segmentStartSample,
                        sampleCount: first - segmentStartSample
                    )
                )
            }
            if let last = track.lastSample, last < segmentEndSample {
                missing.append(
                    RecordingSampleRange(startSample: last, sampleCount: segmentEndSample - last)
                )
            }
            if track.firstSample == nil, segmentEndSample > segmentStartSample {
                missing.append(
                    RecordingSampleRange(
                        startSample: segmentStartSample,
                        sampleCount: segmentEndSample - segmentStartSample
                    )
                )
            }
            return RecordingTrackCoverage(
                role: track.role,
                sampleRate: track.sampleRate,
                channelCount: track.channelCount,
                wasActive: track.wasActive,
                firstSample: track.firstSample,
                lastSample: track.lastSample,
                missingRanges: Self.merged(missing),
                writerSynthesizedSilenceFrames: track.writerSynthesizedSilenceFrames
            )
        }
        return RecordingSegmentCoverage(
            segmentIndex: segmentIndex,
            segmentStartSample: segmentStartSample,
            segmentEndSample: segmentEndSample,
            tracks: tracks
        )
    }

    /// Sorts and merges overlapping or adjacent sample ranges.
    private static func merged(_ ranges: [RecordingSampleRange]) -> [RecordingSampleRange] {
        let ordered = ranges.sorted { $0.startSample < $1.startSample }
        var result: [RecordingSampleRange] = []
        for range in ordered {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.startSample <= last.startSample + last.sampleCount {
                let end = max(last.endSample, range.endSample)
                result[result.count - 1] = RecordingSampleRange(
                    startSample: last.startSample,
                    sampleCount: end - last.startSample
                )
            } else {
                result.append(range)
            }
        }
        return result
    }
}
