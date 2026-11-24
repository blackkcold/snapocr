import AVFoundation
import CoreMedia
import Foundation

extension ScreenSegmentCoordinator {
    func enqueuePending(_ block: AudioPCMBlock) throws {
        let (total, overflow) = pendingAudioFrames.addingReportingOverflow(block.frameCount)
        guard !overflow, total <= 2 * 48_000 else {
            throw ScreenSegmentCoordinatorError.pendingAudioLimitExceeded
        }
        pendingAudio.append(block)
        pendingAudioFrames = total
    }

    func flushPreEpochAudio() async throws {
        guard let epochHostTime else { return }
        let buffered = pendingAudio
        pendingAudio = []
        pendingAudioFrames = 0
        for block in buffered {
            guard let mapped = mapToScreenEpoch(block, epochHostTime: epochHostTime) else { continue }
            try enqueuePending(mapped)
        }
        if let lastFrame { try await flushAudio(through: sampleIndex(for: lastFrame.presentationTime)) }
    }

    /// Writes every pending block that ends at or before `sample` to the audio sink.
    ///
    /// Flushes are serialized: `sink.append` suspends this actor, and two concurrent
    /// flushes used to write the same pending block twice while skipping another,
    /// which the sink rejects as a non-contiguous range.
    ///
    /// - Parameter sample: Exclusive session sample the caller needs written.
    func flushAudio(through sample: Int64) async throws {
        await acquireAudioFlush()
        do {
            try await writePendingAudio(through: sample)
        } catch {
            releaseAudioFlush()
            throw error
        }
        releaseAudioFlush()
    }

    /// The body of one serialized audio flush.
    ///
    /// Blocks enqueued while the sink append suspends stay pending: only the prefix
    /// observed at entry is consumed, so nothing is overwritten by the final assign.
    ///
    /// - Parameter sample: Exclusive session sample the caller needs written.
    func writePendingAudio(through sample: Int64) async throws {
        guard let sink = currentAudioSink else { return }
        let observedCount = pendingAudio.count
        guard observedCount > 0 else { return }
        var remaining: [AudioPCMBlock] = []
        var remainingFrames = 0
        var consumedFrames = 0
        for block in pendingAudio.prefix(observedCount) {
            consumedFrames += block.frameCount
            let start = block.range.startSample
            let end = start + Int64(block.frameCount)
            if end <= 0 { continue }
            let trimStart = max(0, -start)
            let clippedStart = start + trimStart
            let clippedCount = block.frameCount - Int(trimStart)
            guard clippedCount > 0 else { continue }
            if clippedStart >= sample {
                remaining.append(block)
                remainingFrames += block.frameCount
                continue
            }
            let appendCount = min(clippedCount, Int(sample - clippedStart))
            if appendCount > 0 {
                try await sink.append(
                    slice(
                        block,
                        offset: Int(trimStart),
                        count: appendCount,
                        startSample: clippedStart
                    )
                )
            }
            let suffixCount = clippedCount - appendCount
            if suffixCount > 0 {
                let suffix = slice(
                    block,
                    offset: Int(trimStart) + appendCount,
                    count: suffixCount,
                    startSample: clippedStart + Int64(appendCount)
                )
                remaining.append(suffix)
                remainingFrames += suffixCount
            }
        }
        pendingAudio = remaining + pendingAudio.dropFirst(observedCount)
        pendingAudioFrames = remainingFrames + (pendingAudioFrames - consumedFrames)
    }

    /// Waits until this actor owns the single audio-flush slot.
    func acquireAudioFlush() async {
        if !audioFlushInFlight {
            audioFlushInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            audioFlushWaiters.append(continuation)
        }
    }

    /// Hands the audio-flush slot to the next waiter, or frees it.
    func releaseAudioFlush() {
        if audioFlushWaiters.isEmpty {
            audioFlushInFlight = false
        } else {
            let next = audioFlushWaiters.removeFirst()
            next.resume()
        }
    }

    func mapToScreenEpoch(_ block: AudioPCMBlock, epochHostTime: UInt64) -> AudioPCMBlock? {
        let startSample: Int64
        if block.hostTime >= epochHostTime {
            guard let value = sampleIndex(forHostTime: block.hostTime, epochHostTime: epochHostTime) else { return nil }
            startSample = value
        } else {
            guard let trim = sampleIndex(forHostTime: epochHostTime, epochHostTime: block.hostTime) else { return nil }
            let count = block.frameCount - Int(min(Int64(block.frameCount), trim))
            guard count > 0 else { return nil }
            return slice(block, offset: Int(trim), count: count, startSample: 0)
        }
        return slice(block, offset: 0, count: block.frameCount, startSample: startSample)
    }

    func sampleIndex(forHostTime later: UInt64, epochHostTime earlier: UInt64) -> Int64? {
        guard later >= earlier, hostTicksPerSecond <= UInt64(Int32.max) else { return nil }
        let delta = later - earlier
        guard delta <= UInt64(Int64.max) else { return nil }
        let time = CMTime(value: Int64(delta), timescale: CMTimeScale(hostTicksPerSecond))
        let samples = CMTimeConvertScale(time, timescale: 48_000, method: .roundTowardZero)
        return samples.isValid && samples.isNumeric ? samples.value : nil
    }

    func sampleIndex(for time: CMTime) -> Int64 {
        guard let epoch = planner.recordingEpoch else { return 0 }
        let delta = CMTimeSubtract(time, epoch)
        let samples = CMTimeConvertScale(delta, timescale: 48_000, method: .roundTowardZero)
        return samples.isValid && samples.isNumeric ? samples.value : 0
    }

    func sampleRange(start: CMTime, end: CMTime) throws -> SampleRange {
        let first = sampleIndex(for: start)
        let last = sampleIndex(for: end)
        guard last > first else { throw ScreenSegmentCoordinatorError.invalidFrame }
        return SampleRange(startSample: max(0, first), sampleCount: last - max(0, first))
    }

    func slice(_ block: AudioPCMBlock, offset: Int, count: Int, startSample: Int64) -> AudioPCMBlock {
        let channels = block.channels.map { Array($0[offset..<(offset + count)]) }
        let ticks = UInt64(offset) * hostTicksPerSecond / UInt64(max(1, block.sampleRate))
        return AudioPCMBlock(
            role: block.role,
            range: SampleRange(startSample: startSample, sampleCount: Int64(count)),
            sampleRate: block.sampleRate,
            channelCount: block.channelCount,
            frameCount: count,
            hostTime: block.hostTime.addingReportingOverflow(ticks).overflow ? block.hostTime : block.hostTime + ticks,
            channels: channels,
            isSilence: block.isSilence
        )
    }

    func makeAudioDTO(
        _ commit: CheckpointCommit?,
        sessionRoot: URL,
        hashes: inout [String: String]
    ) throws -> ScreenAudioCheckpointDTO? {
        guard let commit else { return nil }
        var paths: [String: String] = [:]
        for (role, url) in commit.trackURLs {
            let roleName = Self.roleName(role)
            let relative = try RecordingLedgerFileSystem.validateChild(url, under: sessionRoot)
            paths[roleName] = relative
            hashes[relative] = try RecordingLedgerFileSystem.sha256(of: url)
        }
        return ScreenAudioCheckpointDTO(
            checkpointID: commit.checkpointID,
            segmentIndex: commit.segmentIndex,
            startSample: commit.range.startSample,
            sampleCount: commit.range.sampleCount,
            trackFiles: paths,
            committedAt: commit.committedAt
        )
    }
}
