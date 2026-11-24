import AVFoundation
import CoreMedia
import Foundation

/// Codable summary of the audio checkpoint paired with one screen chunk.
public struct ScreenAudioCheckpointDTO: Codable, Sendable, Hashable {
    public let checkpointID: UUID
    public let segmentIndex: Int
    public let startSample: Int64
    public let sampleCount: Int64
    /// Relative paths keyed by stable track role (`system` or `microphone`).
    public let trackFiles: [String: String]
    public let committedAt: Date

    public init(
        checkpointID: UUID,
        segmentIndex: Int,
        startSample: Int64,
        sampleCount: Int64,
        trackFiles: [String: String],
        committedAt: Date
    ) {
        self.checkpointID = checkpointID
        self.segmentIndex = segmentIndex
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.trackFiles = trackFiles
        self.committedAt = committedAt
    }
}

/// Durable journal record for one closed screen-video recovery chunk.
public struct ScreenCheckpointRecord: Codable, Sendable, Hashable {
    public let segmentIndex: Int
    public let chunkIndex: Int
    public let videoURL: URL
    public let videoRange: RecordingSampleRange
    public let audioCheckpoint: ScreenAudioCheckpointDTO?
    public let coverage: RecordingSegmentCoverage
    /// SHA-256 values keyed by session-root-relative media paths.
    public let contentHashes: [String: String]

    public init(
        segmentIndex: Int,
        chunkIndex: Int,
        videoURL: URL,
        videoRange: RecordingSampleRange,
        audioCheckpoint: ScreenAudioCheckpointDTO?,
        coverage: RecordingSegmentCoverage,
        contentHashes: [String: String]
    ) {
        self.segmentIndex = segmentIndex
        self.chunkIndex = chunkIndex
        self.videoURL = videoURL
        self.videoRange = videoRange
        self.audioCheckpoint = audioCheckpoint
        self.coverage = coverage
        self.contentHashes = contentHashes
    }
}

/// Result of durably closing one screen recovery chunk.
public struct ScreenCheckpointCommit: Sendable, Hashable {
    public let segmentIndex: Int
    public let chunkIndex: Int
    public let videoURL: URL
    public let videoRange: SampleRange
    public let audio: CheckpointCommit?
    public let contentHashes: [String: String]

    public init(
        segmentIndex: Int,
        chunkIndex: Int,
        videoURL: URL,
        videoRange: SampleRange,
        audio: CheckpointCommit?,
        contentHashes: [String: String]
    ) {
        self.segmentIndex = segmentIndex
        self.chunkIndex = chunkIndex
        self.videoURL = videoURL
        self.videoRange = videoRange
        self.audio = audio
        self.contentHashes = contentHashes
    }
}

/// Errors raised while coordinating screen chunks and stable audio checkpoints.
public enum ScreenSegmentCoordinatorError: Error, Equatable, Sendable {
    case invalidFrame
    case invalidAudio
    case pendingAudioLimitExceeded
    case noOpenVideoChunk
    case noVideoFrames
    case sealContextRequired
    case durabilityFailed
}

/// Coordinates one screen stream, durable video chunks, and a stable audio sink facade.
public actor ScreenSegmentCoordinator: AudioCheckpointSink {
    /// Ledger identity for this screen session.
    public nonisolated let sessionID: UUID

    private let planner: VideoSegmentPlanner
    private let videoWriterFactory: @Sendable (ScreenBoundary) throws -> ScreenVideoWriterBridge
    private let audioSinkFactory: @Sendable (ScreenBoundary) throws -> any SegmentCheckpointSink
    private let ledger: RecordingSessionLedger
    private let seal: ScreenSegmentSealService
    private let hostTicksPerSecond = AudioSourceTimestampMapper.nativeHostTicksPerSecond()

    private var sealContext: RecordingSealContext?
    private var currentAudioSink: (any SegmentCheckpointSink & Sendable)?
    private var currentVideoWriter: ScreenVideoWriterBridge?
    private var currentChunkStart: ScreenBoundary?
    private var currentSegmentIndex: Int?
    private var currentSegmentID: UUID?
    private var epochHostTime: UInt64?
    private var epochPresentationTime: CMTime?
    private var nextFrameIndex: Int64 = 0
    private var lastFrame: VideoFrameSample?
    /// The most recent source frame, retained to hold the picture during static periods.
    ///
    /// ScreenCaptureKit is change-driven: a still screen stops producing frames. One
    /// retained buffer lets the coordinator repeat it with advancing timestamps, so a
    /// static recording still has a timeline of the real length.
    private var lastSampleBuffer: CMSampleBuffer?
    private var pendingAudio: [AudioPCMBlock] = []
    private var pendingAudioFrames = 0
    /// Serializes audio flushes; `sink.append` suspends this actor.
    private var audioFlushInFlight = false
    private var audioFlushWaiters: [CheckedContinuation<Void, Never>] = []
    private var screenRecords: [Int: [ScreenCheckpointRecord]] = [:]
    private var lastSealedSegment: SealedSegment?
    private var completedVideoDropCount: Int64 = 0
    private var completedWriterDiagnostics = ScreenWriterDiagnostics.idle

    /// Creates a screen coordinator. The returned coordinator itself is the stable audio sink.
    public init(
        planner: VideoSegmentPlanner,
        videoWriterFactory: @escaping @Sendable (ScreenBoundary) throws -> ScreenVideoWriterBridge,
        audioSinkFactory: @escaping @Sendable (ScreenBoundary) throws -> any SegmentCheckpointSink,
        ledger: RecordingSessionLedger,
        seal: ScreenSegmentSealService
    ) {
        self.planner = planner
        self.videoWriterFactory = videoWriterFactory
        self.audioSinkFactory = audioSinkFactory
        self.ledger = ledger
        self.seal = seal
        sessionID = ledger.sessionID
    }

    /// Registers the screen session before capture starts.
    public func registerSession(kind: RecordingKind, layout: AudioOutputLayout) async throws {
        try await ledger.register(RecordingSessionRecord(
            id: sessionID,
            kind: kind,
            layout: layout,
            startedAt: Date(),
            segments: []
        ))
    }

    /// The host-time origin established by the first accepted sync video frame.
    public func recordingEpochHostTime() -> UInt64? { epochHostTime }

    /// This session's material directory, read-only.
    ///
    /// Used to give a failed finalization an actionable "show in Finder" target.
    /// Nothing in this type moves or deletes these files.
    public nonisolated var materialRoot: URL { ledger.sessionRoot }

    /// Number of frames dropped by completed and currently active video writers.
    public func droppedVideoFrameCount() -> Int64 {
        let active = currentVideoWriter?.droppedFrameCount ?? 0
        let (total, overflow) = completedVideoDropCount.addingReportingOverflow(active)
        return overflow ? Int64.max : total
    }

    /// Whether the active video writer has accepted at least one frame.
    ///
    /// This is set only after `AVAssetWriterInput.append` accepts a sample. Queue
    /// acceptance in `ScreenRecordingEngine` is not enough: frames can still be
    /// rejected or dropped before they reach the writer.
    public private(set) var hasWrittenVideoFrame = false

    /// Privacy-safe writer counters for the whole session.
    ///
    /// Combines every finished chunk with the live one, so a failure that closed a
    /// chunk is still visible while the next chunk writes.
    public func writerDiagnostics() -> ScreenWriterDiagnostics {
        completedWriterDiagnostics.combined(with: currentVideoWriter?.diagnostics ?? .idle)
    }

    /// Published screen MP4 URLs in segment order, read from the durable ledger.
    public func publishedVideoURLs() async throws -> [URL] {
        try await ledger.snapshot().segments
            .filter { $0.state == .published }
            .sorted { $0.index < $1.index }
            .compactMap(\.videoURL)
    }

    /// Supplies immutable destination and metadata settings before capture starts.
    public func configureSealContext(_ context: RecordingSealContext) {
        sealContext = context
    }

    /// Appends a 48 kHz audio block to the current underlying T7 sink.
    public func append(_ block: AudioPCMBlock) async throws {
        guard block.frameCount > 0,
              block.sampleRate == 48_000,
              block.range.sampleCount == Int64(block.frameCount),
              block.channelCount == block.channels.count,
              block.channels.allSatisfy({ $0.count == block.frameCount })
        else { throw ScreenSegmentCoordinatorError.invalidAudio }

        guard let epochHostTime else {
            try enqueuePending(block)
            return
        }
        guard let mapped = mapToScreenEpoch(block, epochHostTime: epochHostTime) else { return }
        try enqueuePending(mapped)
        if let lastFrame {
            let end = sampleIndex(for: lastFrame.presentationTime)
            try await flushAudio(through: end)
        }
    }

    /// Commits the current underlying audio checkpoint without replacing this facade.
    public func commitCheckpoint() async throws -> CheckpointCommit {
        guard let currentAudioSink else { throw RecordingCheckpointError.emptyCheckpoint }
        return try await currentAudioSink.commitCheckpoint()
    }

    /// Appends one captured video sample and acts on any frame-aligned boundary.
    public func append(video sampleBuffer: CMSampleBuffer, at hostTime: UInt64) async throws {
        _ = try await processTick(hostTime: hostTime)
        let frame = try Self.frameSample(sampleBuffer, index: nextFrameIndex)
        nextFrameIndex += 1
        let decision = planner.append(frame)

        switch decision {
        case .keepCurrent:
            if epochHostTime == nil, frame.isSync {
                epochHostTime = hostTime
                epochPresentationTime = frame.presentationTime
            }
            if currentVideoWriter == nil, frame.isSync {
                try openSegmentIfNeeded(startingAt: frame)
                try openVideoChunk(startingAt: frame)
                try await flushPreEpochAudio()
            }
            if let writer = currentVideoWriter {
                if try writer.append(video: sampleBuffer) { hasWrittenVideoFrame = true }
                lastFrame = frame
                lastSampleBuffer = sampleBuffer
                try await flushAudio(through: sampleIndex(for: frame.presentationTime))
            }
        case .closeChunk(let boundary), .cachedChunkBoundary(let boundary):
            try await closeCurrentChunk(at: boundary)
            try openVideoChunk(startingAt: frame)
            if try currentVideoWriter?.append(video: sampleBuffer) == true { hasWrittenVideoFrame = true }
            lastFrame = frame
            lastSampleBuffer = sampleBuffer
            try await flushAudio(through: sampleIndex(for: frame.presentationTime))
        case .closeSegment(let boundary):
            try await closeCurrentChunk(at: boundary)
            lastSealedSegment = try await sealCurrentSegment()
            currentSegmentIndex = nil
            currentSegmentID = nil
            currentAudioSink = nil
            try openSegmentIfNeeded(startingAt: frame)
            try openVideoChunk(startingAt: frame)
            if try currentVideoWriter?.append(video: sampleBuffer) == true { hasWrittenVideoFrame = true }
            lastFrame = frame
            lastSampleBuffer = sampleBuffer
            try await flushAudio(through: sampleIndex(for: frame.presentationTime))
        }
    }

    /// Advances sparse/static captures and closes a due checkpoint without requiring a frame callback.
    public func tick(hostTime: UInt64) async throws {
        let decision = try await processTick(hostTime: hostTime)
        if let end = decision?.boundaryEndTime {
            try await flushAudio(through: sampleIndex(for: end))
        }
        try await appendFreezeFrameIfNeeded(hostTime: hostTime)
    }

    /// Closes and journals the current video chunk.
    public func closeCheckpoint() async throws -> ScreenCheckpointCommit {
        guard let start = currentChunkStart, let lastFrame else {
            throw ScreenSegmentCoordinatorError.noOpenVideoChunk
        }
        let endTime = CMTimeAdd(lastFrame.presentationTime, lastFrame.duration)
        let boundary = ScreenBoundary(
            kind: .chunk,
            segmentIndex: start.segmentIndex,
            chunkIndex: start.chunkIndex,
            startFrameIndex: start.startFrameIndex,
            endFrameIndex: lastFrame.index + 1,
            startTime: start.startTime,
            endTime: endTime,
            firstFrameIsSync: start.firstFrameIsSync
        )
        return try await closeCurrentChunk(at: boundary)
    }

    /// Closes the final chunk and seals the visible segment.
    public func closeSegment() async throws -> SealedSegment {
        if currentVideoWriter != nil { _ = try await closeCheckpoint() }
        guard let result = try await sealCurrentSegment() else {
            if let lastSealedSegment { return lastSealedSegment }
            throw ScreenSegmentCoordinatorError.noVideoFrames
        }
        currentVideoWriter = nil
        currentChunkStart = nil
        currentAudioSink = nil
        currentSegmentIndex = nil
        currentSegmentID = nil
        return result
    }

    /// Reads this ledger's durable screen checkpoint journal.
    public func screenCheckpoints(sessionID: UUID) async throws -> [ScreenCheckpointRecord] {
        try await ledger.screenCheckpoints(sessionID: sessionID)
    }

    /// Persists a previously synced screen checkpoint through the session journal.
    public func commitScreenCheckpoint(_ record: ScreenCheckpointRecord) async throws {
        try await ledger.commitScreenCheckpoint(record)
    }

    /// Repeats the last captured frame when the source has gone quiet.
    ///
    /// ScreenCaptureKit is change-driven, so a still screen stops producing frames
    /// while the recording clock keeps running. Writing the retained frame again
    /// with the elapsed gap as its duration keeps the video timeline equal to the
    /// real recording length instead of collapsing to the last burst of frames.
    ///
    /// - Parameter hostTime: The current monotonic host time.
    private func appendFreezeFrameIfNeeded(hostTime: UInt64) async throws {
        guard currentVideoWriter != nil,
              let sample = lastSampleBuffer,
              let epochHostTime,
              let epochPresentationTime,
              hostTime > epochHostTime,
              let lastFrame
        else { return }
        let elapsed = Double(hostTime - epochHostTime) / Double(hostTicksPerSecond)
        let target = CMTimeAdd(
            epochPresentationTime,
            CMTime(seconds: elapsed, preferredTimescale: 1_000_000)
        )
        let lastEnd = CMTimeAdd(lastFrame.presentationTime, lastFrame.duration)
        let gap = CMTimeSubtract(target, lastEnd)
        let minimumGap = CMTime(seconds: Self.freezeFrameInterval, preferredTimescale: 1_000_000)
        guard gap.isValid, gap.isNumeric, CMTimeCompare(gap, minimumGap) >= 0 else { return }

        var timing = CMSampleTimingInfo(
            duration: gap,
            presentationTimeStamp: lastEnd,
            decodeTimeStamp: .invalid
        )
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copied
        )
        guard status == noErr, let copied else { return }
        try await append(video: copied, at: hostTime)
    }

    /// Minimum elapsed time before the retained frame is written again.
    private static let freezeFrameInterval: TimeInterval = 0.5

    private func processTick(hostTime: UInt64) async throws -> ScreenBoundaryDecision? {
        let decision = planner.tick(hostTime: hostTime)
        switch decision {
        case .keepCurrent:
            if let epochHostTime,
               let sample = sampleIndex(forHostTime: hostTime, epochHostTime: epochHostTime) {
                try await flushAudio(through: sample)
            }
            return nil
        case .closeChunk(let boundary), .cachedChunkBoundary(let boundary):
            _ = try await closeCurrentChunk(at: boundary)
            return decision
        case .closeSegment(let boundary):
            _ = try await closeCurrentChunk(at: boundary)
            lastSealedSegment = try await sealCurrentSegment()
            currentSegmentIndex = nil
            currentSegmentID = nil
            currentAudioSink = nil
            return decision
        }
    }

    private func openSegmentIfNeeded(startingAt frame: VideoFrameSample) throws {
        guard currentSegmentIndex == nil else { return }
        let index = planner.currentSegmentIndex
        let start = frame.presentationTime
        let end = CMTimeAdd(start, CMTime(seconds: 3_540, preferredTimescale: 1_000_000))
        let visibleBoundary = ScreenBoundary(
            kind: .segment,
            segmentIndex: index,
            chunkIndex: 0,
            startFrameIndex: frame.index,
            endFrameIndex: frame.index + 1,
            startTime: start,
            endTime: end,
            firstFrameIsSync: frame.isSync
        )
        currentAudioSink = try audioSinkFactory(visibleBoundary)
        currentSegmentIndex = index
        currentSegmentID = UUID()
    }

    private func openVideoChunk(startingAt frame: VideoFrameSample) throws {
        guard currentVideoWriter == nil else { return }
        guard frame.isSync else { return }
        let boundary = ScreenBoundary(
            kind: .chunk,
            segmentIndex: planner.currentSegmentIndex,
            chunkIndex: planner.currentChunkIndex,
            startFrameIndex: frame.index,
            endFrameIndex: frame.index + 1,
            startTime: frame.presentationTime,
            endTime: CMTimeAdd(frame.presentationTime, frame.duration),
            firstFrameIsSync: true
        )
        currentVideoWriter = try videoWriterFactory(boundary)
        currentChunkStart = boundary
    }

    @discardableResult
    private func closeCurrentChunk(at boundary: ScreenBoundary) async throws -> ScreenCheckpointCommit {
        guard let writer = currentVideoWriter,
              let start = currentChunkStart,
              let segmentIndex = currentSegmentIndex
        else { throw ScreenSegmentCoordinatorError.noOpenVideoChunk }
        let sessionRoot = ledger.sessionRoot

        try await flushAudio(through: sampleIndex(for: boundary.endTime))
        let result: VideoChunkResult
        do {
            result = try await writer.finish()
        } catch {
            completedWriterDiagnostics = completedWriterDiagnostics.combined(with: writer.diagnostics)
            throw error
        }
        completedWriterDiagnostics = completedWriterDiagnostics.combined(with: writer.diagnostics)
        let (nextDropCount, dropOverflow) = completedVideoDropCount.addingReportingOverflow(result.droppedFrameCount)
        completedVideoDropCount = dropOverflow ? Int64.max : nextDropCount
        do {
            try RecordingLedgerFileSystem.syncFile(result.url)
            try RecordingLedgerFileSystem.syncDirectory(result.url.deletingLastPathComponent())
        } catch { throw ScreenSegmentCoordinatorError.durabilityFailed }

        let range = try sampleRange(start: start.startTime, end: boundary.endTime)
        let audioCommit: CheckpointCommit?
        if let currentAudioSink {
            do {
                audioCommit = try await currentAudioSink.commitCheckpoint()
            } catch let error as RecordingCheckpointError where error == .emptyCheckpoint {
                audioCommit = nil
            }
        } else {
            audioCommit = nil
        }
        var hashes: [String: String] = [:]
        let videoRelativePath = try RecordingLedgerFileSystem.validateChild(result.url, under: sessionRoot)
        hashes[videoRelativePath] = try RecordingLedgerFileSystem.sha256(of: result.url)
        let dto = try makeAudioDTO(audioCommit, sessionRoot: sessionRoot, hashes: &hashes)
        let coverage = try makeCoverage(audioCommit, videoRange: range)
        let record = ScreenCheckpointRecord(
            segmentIndex: segmentIndex,
            chunkIndex: start.chunkIndex,
            videoURL: result.url,
            videoRange: RecordingSampleRange(startSample: range.startSample, sampleCount: range.sampleCount),
            audioCheckpoint: dto,
            coverage: coverage,
            contentHashes: hashes
        )
        try await ledger.commitScreenCheckpoint(record)
        screenRecords[segmentIndex, default: []].append(record)
        currentVideoWriter = nil
        currentChunkStart = nil
        lastSampleBuffer = nil
        return ScreenCheckpointCommit(
            segmentIndex: segmentIndex,
            chunkIndex: start.chunkIndex,
            videoURL: result.url,
            videoRange: range,
            audio: audioCommit,
            contentHashes: hashes
        )
    }

    private func sealCurrentSegment() async throws -> SealedSegment? {
        guard let segmentIndex = currentSegmentIndex,
              let segmentID = currentSegmentID,
              let context = sealContext,
              let checkpoints = screenRecords[segmentIndex],
              !checkpoints.isEmpty
        else { return nil }
        let completedAudioBundle = try await currentAudioSink?.finishSegmentBundle()
        let audioBundle = completedAudioBundle.flatMap {
            $0.checkpoints.checkpoints.isEmpty ? nil : $0
        }
        let sealed = try await seal.seal(
            checkpoints,
            audio: audioBundle,
            segmentID: segmentID,
            context: context
        )
        guard let videoURL = sealed.videoURL else {
            throw RecordingSessionLedgerError.invalidPublication
        }
        _ = try await ledger.publishIntent(segmentID: segmentID)
        var files: [String: String] = [:]
        var trackMap: [String: Int] = [:]
        for (role, url) in sealed.files {
            let name = Self.roleName(role)
            files[name] = try RecordingLedgerFileSystem.validateChild(
                url,
                under: context.destinationDirectory
            )
            guard let index = sealed.trackMap[role] else {
                throw RecordingSessionLedgerError.invalidPublication
            }
            trackMap[name] = index
        }
        try await ledger.markPublished(PublishedSegment(
            id: sealed.segmentID,
            index: sealed.index,
            files: files,
            startSample: sealed.effectiveRange.startSample,
            sampleCount: sealed.effectiveRange.sampleCount,
            trackMap: trackMap,
            missingRanges: (audioBundle?.coverage.tracks ?? []).filter(\.wasActive).flatMap(\.missingRanges),
            state: .published,
            videoURL: videoURL,
            videoTrackIndex: sealed.videoTrackIndex
        ))
        screenRecords[segmentIndex] = nil
        return sealed
    }

    private func enqueuePending(_ block: AudioPCMBlock) throws {
        let (total, overflow) = pendingAudioFrames.addingReportingOverflow(block.frameCount)
        guard !overflow, total <= 2 * 48_000 else {
            throw ScreenSegmentCoordinatorError.pendingAudioLimitExceeded
        }
        pendingAudio.append(block)
        pendingAudioFrames = total
    }

    private func flushPreEpochAudio() async throws {
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
    private func flushAudio(through sample: Int64) async throws {
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
    private func writePendingAudio(through sample: Int64) async throws {
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
    private func acquireAudioFlush() async {
        if !audioFlushInFlight {
            audioFlushInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            audioFlushWaiters.append(continuation)
        }
    }

    /// Hands the audio-flush slot to the next waiter, or frees it.
    private func releaseAudioFlush() {
        if audioFlushWaiters.isEmpty {
            audioFlushInFlight = false
        } else {
            let next = audioFlushWaiters.removeFirst()
            next.resume()
        }
    }

    private func mapToScreenEpoch(_ block: AudioPCMBlock, epochHostTime: UInt64) -> AudioPCMBlock? {
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

    private func sampleIndex(forHostTime later: UInt64, epochHostTime earlier: UInt64) -> Int64? {
        guard later >= earlier, hostTicksPerSecond <= UInt64(Int32.max) else { return nil }
        let delta = later - earlier
        guard delta <= UInt64(Int64.max) else { return nil }
        let time = CMTime(value: Int64(delta), timescale: CMTimeScale(hostTicksPerSecond))
        let samples = CMTimeConvertScale(time, timescale: 48_000, method: .roundTowardZero)
        return samples.isValid && samples.isNumeric ? samples.value : nil
    }

    private func sampleIndex(for time: CMTime) -> Int64 {
        guard let epoch = planner.recordingEpoch else { return 0 }
        let delta = CMTimeSubtract(time, epoch)
        let samples = CMTimeConvertScale(delta, timescale: 48_000, method: .roundTowardZero)
        return samples.isValid && samples.isNumeric ? samples.value : 0
    }

    private func sampleRange(start: CMTime, end: CMTime) throws -> SampleRange {
        let first = sampleIndex(for: start)
        let last = sampleIndex(for: end)
        guard last > first else { throw ScreenSegmentCoordinatorError.invalidFrame }
        return SampleRange(startSample: max(0, first), sampleCount: last - max(0, first))
    }

    private func slice(_ block: AudioPCMBlock, offset: Int, count: Int, startSample: Int64) -> AudioPCMBlock {
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

    private func makeAudioDTO(
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

    private func makeCoverage(_ commit: CheckpointCommit?, videoRange: SampleRange) throws -> RecordingSegmentCoverage {
        guard let commit, let firstURL = commit.trackURLs.values.first else {
            return RecordingSegmentCoverage(
                segmentIndex: currentSegmentIndex ?? 0,
                segmentStartSample: videoRange.startSample,
                segmentEndSample: videoRange.startSample + videoRange.sampleCount,
                tracks: []
            )
        }
        let sidecar = firstURL.deletingLastPathComponent()
            .appendingPathComponent("checkpoint-\(commit.checkpointID.uuidString.lowercased()).json")
        let record = try RecordingCheckpointSidecar.decode(try Data(contentsOf: sidecar), path: sidecar.path)
        let end = commit.range.startSample + commit.range.sampleCount
        let tracks = record.tracks.map { track in
            let first = commit.range.startSample
            var missing: [RecordingSampleRange] = []
            if first > videoRange.startSample {
                missing.append(
                    RecordingSampleRange(
                        startSample: videoRange.startSample,
                        sampleCount: first - videoRange.startSample
                    )
                )
            }
            let videoEnd = videoRange.startSample + videoRange.sampleCount
            if end < videoEnd {
                missing.append(RecordingSampleRange(startSample: end, sampleCount: videoEnd - end))
            }
            return RecordingTrackCoverage(
                role: track.role,
                sampleRate: track.sampleRate,
                channelCount: track.channelCount,
                wasActive: true,
                firstSample: first,
                lastSample: end,
                missingRanges: missing,
                writerSynthesizedSilenceFrames: track.writerSynthesizedSilenceFrames
            )
        }
        return RecordingSegmentCoverage(
            segmentIndex: currentSegmentIndex ?? 0,
            segmentStartSample: videoRange.startSample,
            segmentEndSample: videoRange.startSample + videoRange.sampleCount,
            tracks: tracks
        )
    }

    private static func frameSample(_ sampleBuffer: CMSampleBuffer, index: Int64) throws -> VideoFrameSample {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        else { throw ScreenSegmentCoordinatorError.invalidFrame }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { throw ScreenSegmentCoordinatorError.invalidFrame }
        let sourceDuration = CMSampleBufferGetDuration(sampleBuffer)
        let duration = sourceDuration.isValid && sourceDuration.isNumeric && CMTimeCompare(sourceDuration, .zero) > 0
            ? sourceDuration
            : CMTime(value: 1, timescale: 30)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? NSNumber
        return VideoFrameSample(
            index: index,
            presentationTime: pts,
            decodeTime: CMSampleBufferGetDecodeTimeStamp(sampleBuffer),
            duration: duration,
            isSync: !(notSync?.boolValue ?? false)
        )
    }

    private static func roleName(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed: "mixed"
        case .system: "system"
        case .microphone: "microphone"
        }
    }
}

private extension ScreenBoundaryDecision {
    var boundaryEndTime: CMTime? {
        switch self {
        case .keepCurrent: nil
        case .closeChunk(let boundary),
            .closeSegment(let boundary),
            .cachedChunkBoundary(let boundary):
            boundary.endTime
        }
    }
}
