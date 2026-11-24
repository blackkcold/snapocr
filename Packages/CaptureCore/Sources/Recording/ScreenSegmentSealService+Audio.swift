import AVFoundation
import CoreMedia
import Foundation

private struct SealAudioContext {
    let sink: AudioAACStreamSink
    let segmentStartSample: Int64
    let segmentEndSample: Int64
    let mediaOrigin: CMTime
}

extension ScreenSegmentSealService {
    func appendAudioTracks(
        roleURLs: [RecordingTrackRole: [URL]],
        audioSinks: [RecordingTrackRole: AudioAACStreamSink],
        segmentStartSample: Int64,
        segmentEndSample: Int64,
        mediaOrigin: CMTime
    ) async throws {
        for (role, sink) in audioSinks {
            guard let urls = roleURLs[role] else { continue }
            let context = SealAudioContext(
                sink: sink,
                segmentStartSample: segmentStartSample,
                segmentEndSample: segmentEndSample,
                mediaOrigin: mediaOrigin
            )
            try await appendAudio(urls: urls, role: role, context: context)
            try sink.finish()
        }
    }

    func appendVideo(
        from url: URL,
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) async throws {
        let source = try await videoTrack(for: url)
        logger.info("screen.seal append chunk track ready")
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: source.asset) } catch {
            logger.error("screen.seal reader init failed: \(String(describing: error))")
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: nil)
        guard reader.canAdd(output) else {
            logger.error("screen.seal reader cannot add the video output")
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
        reader.add(output)
        guard reader.startReading() else {
            logger.error("screen.seal reader start failed: \(String(describing: reader.error))")
            throw ScreenSegmentSealError.videoTrackUnavailable
        }

        var sawSample = false
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw ScreenSegmentSealError.writerFailed }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.append(sample) else { throw ScreenSegmentSealError.writerFailed }
            sawSample = true
            sampleCount += 1
        }
        logger.info(
            "screen.seal chunk samples=\(sampleCount) readerStatus=\(reader.status.rawValue)"
        )
        guard reader.status == .completed, sawSample else {
            throw ScreenSegmentSealError.videoTrackUnavailable
        }
    }

    private func appendAudio(
        urls: [URL],
        role: RecordingTrackRole,
        context: SealAudioContext
    ) async throws {
        var cursor = context.segmentStartSample
        guard let firstURL = urls.first else { throw ScreenSegmentSealError.audioReadFailed }
        let channels = try audioFormat(at: firstURL).channelCount
        let ordered = try urls.map { url -> (URL, CheckpointCommit) in
            guard let commit = try audioCommit(for: url) else { throw ScreenSegmentSealError.rangeMismatch }
            return (url, commit)
        }.sorted { $0.1.range.startSample < $1.1.range.startSample }
        for (url, commit) in ordered {
            guard commit.range.startSample >= cursor,
                  commit.range.startSample + commit.range.sampleCount <= context.segmentEndSample
            else { throw ScreenSegmentSealError.rangeMismatch }
            if commit.range.startSample > cursor {
                try await appendSilence(
                    role: role,
                    start: cursor,
                    count: commit.range.startSample - cursor,
                    channelCount: channels,
                    context: context
                )
            }
            try await appendCAF(
                at: url,
                role: role,
                startSample: commit.range.startSample,
                expectedFrames: commit.range.sampleCount,
                context: context
            )
            cursor = commit.range.startSample + commit.range.sampleCount
        }
        if cursor < context.segmentEndSample {
            try await appendSilence(
                role: role,
                start: cursor,
                count: context.segmentEndSample - cursor,
                channelCount: channels,
                context: context
            )
        }
    }

    private func appendCAF(
        at url: URL,
        role: RecordingTrackRole,
        startSample: Int64,
        expectedFrames: Int64,
        context: SealAudioContext
    ) async throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ScreenSegmentSealError.audioReadFailed }
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
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
            } catch {
                throw ScreenSegmentSealError.audioReadFailed
            }
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
            try await context.sink.append(
                block,
                segmentStartSample: context.segmentStartSample,
                mediaOrigin: context.mediaOrigin
            )
            sample += Int64(count)
            remaining -= Int64(count)
        }
    }

    private func appendSilence(
        role: RecordingTrackRole,
        start: Int64,
        count: Int64,
        channelCount: Int,
        context: SealAudioContext
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
            try await context.sink.append(
                block,
                segmentStartSample: context.segmentStartSample,
                mediaOrigin: context.mediaOrigin
            )
            cursor += Int64(frames)
            remaining -= Int64(frames)
        }
    }

    func audioFormat(at url: URL) throws -> (sampleRate: Int, channelCount: Int) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ScreenSegmentSealError.audioReadFailed }
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
            let roleURLs = Dictionary(
                uniqueKeysWithValues: record.tracks.compactMap { track -> (RecordingTrackRole, URL)? in
                    guard let role = Self.role(for: track.role) else { return nil }
                    return (role, directory.appendingPathComponent(track.fileName))
                }
            )
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
}
