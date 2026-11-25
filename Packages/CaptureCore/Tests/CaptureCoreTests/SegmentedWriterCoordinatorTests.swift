import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

struct T7CAFContents {
    let sampleRate: Double
    let channelCount: Int
    let frames: Int64
    let bitDepth: Int?
    let isFloat: Bool?
    let channels: [[Float]]
}
enum T7TestError: Error {
    case unreadableChannels
}
struct T7InjectedFault: Error {}
struct T7FaultInjector: RecordingCheckpointFaultInjecting {
    var failWrite: Set<RecordingTrackRole> = []
    var failClose: Set<RecordingTrackRole> = []
    var failFileSync: Set<RecordingTrackRole?> = []
    var failSidecarRename = false
    var failDirectorySync = false
    func checkWrite(role: RecordingTrackRole?) throws {
        if let role, failWrite.contains(role) {
            throw T7InjectedFault()
        }
    }
    func checkClose(role: RecordingTrackRole?) throws {
        if let role, failClose.contains(role) {
            throw T7InjectedFault()
        }
    }
    func checkFileSync(role: RecordingTrackRole?) throws {
        if failFileSync.contains(role) {
            throw T7InjectedFault()
        }
    }
    func checkSidecarRename() throws {
        if failSidecarRename {
            throw T7InjectedFault()
        }
    }
    func checkDirectorySync() throws {
        if failDirectorySync {
            throw T7InjectedFault()
        }
    }
}
extension T7TestSupport {
    static func captureError(_ operation: () async throws -> Void) async -> RecordingCheckpointError? {
        do {
            try await operation()
            return nil
        } catch let error as RecordingCheckpointError {
            return error
        } catch {
            return nil
        }
    }
    static func readCAF(at url: URL) throws -> T7CAFContents {
        let file = try AVAudioFile(forReading: url)
        let settings = file.fileFormat.settings
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            "Unable to allocate a PCM buffer"
        )
        try file.read(into: buffer)
        var channels: [[Float]] = []
        if let data = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                channels.append(Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))))
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))
                channels.append(samples.map { Float($0) / 32_768 })
            }
        } else {
            throw T7TestError.unreadableChannels
        }
        return T7CAFContents(
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount),
            frames: file.length,
            bitDepth: settings[AVLinearPCMBitDepthKey] as? Int,
            isFloat: settings[AVLinearPCMIsFloatKey] as? Bool,
            channels: channels
        )
    }
}
final class T7EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
final class T7SinkRegistry: @unchecked Sendable {
    let events = T7EventLog()
    private let lock = NSLock()
    private var sinks: [Int: T7SpySink] = [:]
    private var boundaries: [Int: SegmentBoundary] = [:]
    func makeSink(for boundary: SegmentBoundary, sampleRate: Int = 8_000) -> T7SpySink {
        let sink = T7SpySink(boundary: boundary, sampleRate: sampleRate, eventLog: events)
        lock.lock()
        sinks[boundary.index] = sink
        boundaries[boundary.index] = boundary
        lock.unlock()
        events.record("create-\(boundary.index)")
        return sink
    }
    func sink(at index: Int) -> T7SpySink? {
        lock.lock()
        defer { lock.unlock() }
        return sinks[index]
    }
    var createdBoundaries: [SegmentBoundary] {
        lock.lock()
        defer { lock.unlock() }
        return boundaries.values.sorted { $0.index < $1.index }
    }
}
final class T7LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) {
        storage = value
    }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
actor T7SpySink: SegmentCheckpointSink {
    nonisolated let segmentBoundary: SegmentBoundary
    private let sampleRate: Int
    private let eventLog: T7EventLog
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var pending: [RecordingTrackRole: (start: Int64, end: Int64)] = [:]
    private var rangesByRole: [RecordingTrackRole: [SampleRange]] = [:]
    private var commits: [CheckpointCommit] = []
    private var lastCommit: CheckpointCommit?
    private var failFinishCount = 0
    private var failCommitCount = 0
    private var closed = false
    private(set) var commitCount = 0
    private(set) var finishCount = 0
    private(set) var appendCount = 0
    init(boundary: SegmentBoundary, sampleRate: Int, eventLog: T7EventLog) {
        segmentBoundary = boundary
        self.sampleRate = sampleRate
        self.eventLog = eventLog
    }
    func setFailFinishCount(_ count: Int) {
        failFinishCount = count
    }
    func setFailCommitCount(_ count: Int) {
        failCommitCount = count
    }
    func appendedRanges(for role: RecordingTrackRole) -> [SampleRange] {
        rangesByRole[role] ?? []
    }
    func append(_ block: AudioPCMBlock) async throws {
        appendCount += 1
        eventLog.record(
            "append-\(segmentBoundary.index)-\(block.range.startSample)-\(block.range.sampleCount)"
        )
        rangesByRole[block.role, default: []].append(block.range)
        let end = block.range.startSample + block.range.sampleCount
        if let existing = pending[block.role] {
            pending[block.role] = (existing.start, max(existing.end, end))
        } else {
            pending[block.role] = (block.range.startSample, end)
        }
    }
    func commitCheckpoint() async throws -> CheckpointCommit {
        commitCount += 1
        if failCommitCount > 0 {
            failCommitCount -= 1
            throw RecordingCheckpointError.trackRangesDoNotMatch
        }
        guard !pending.isEmpty else {
            if let lastCommit {
                return lastCommit
            }
            throw RecordingCheckpointError.emptyCheckpoint
        }
        let starts = pending.values.map(\.start)
        let ends = pending.values.map(\.end)
        let start = starts.min() ?? segmentBoundary.startSample
        let end = ends.max() ?? start
        let commit = CheckpointCommit(
            checkpointID: UUID(),
            segmentIndex: segmentBoundary.index,
            range: SampleRange(startSample: start, sampleCount: end - start),
            trackURLs: [:],
            committedAt: fixedDate
        )
        pending.removeAll()
        commits.append(commit)
        lastCommit = commit
        return commit
    }
    func finishSegment() async throws -> SegmentCheckpointSet {
        finishCount += 1
        if failFinishCount > 0 {
            failFinishCount -= 1
            throw RecordingCheckpointError.writeFailed(role: nil, reason: "injectedFinishFailure")
        }
        if !pending.isEmpty {
            _ = try await commitCheckpoint()
        }
        closed = true
        return SegmentCheckpointSet(segmentIndex: segmentBoundary.index, checkpoints: commits)
    }
    func finishSegmentBundle() async throws -> RecordingSegmentCheckpointBundle {
        let set = try await finishSegment()
        let end =
            commits.map { $0.range.startSample + $0.range.sampleCount }.max()
            ?? segmentBoundary.startSample
        let coverage = RecordingSegmentCoverage(
            segmentIndex: segmentBoundary.index,
            segmentStartSample: segmentBoundary.startSample,
            segmentEndSample: end,
            tracks: []
        )
        return RecordingSegmentCheckpointBundle(checkpoints: set, coverage: coverage)
    }
    var isClosed: Bool {
        closed
    }
}
actor T7GateSink: SegmentCheckpointSink {
    nonisolated let segmentBoundary: SegmentBoundary
    private var hasEntered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(boundary: SegmentBoundary) {
        segmentBoundary = boundary
    }
    func waitUntilAppendEntered() async {
        if hasEntered {
            return
        }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }
    func releaseAppend() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
    func append(_ block: AudioPCMBlock) async throws {
        hasEntered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }
    func commitCheckpoint() async throws -> CheckpointCommit {
        throw RecordingCheckpointError.emptyCheckpoint
    }

    func finishSegment() async throws -> SegmentCheckpointSet {
        SegmentCheckpointSet(segmentIndex: segmentBoundary.index, checkpoints: [])
    }
    func finishSegmentBundle() async throws -> RecordingSegmentCheckpointBundle {
        RecordingSegmentCheckpointBundle(
            checkpoints: SegmentCheckpointSet(segmentIndex: segmentBoundary.index, checkpoints: []),
            coverage: RecordingSegmentCoverage(
                segmentIndex: segmentBoundary.index,
                segmentStartSample: segmentBoundary.startSample,
                segmentEndSample: segmentBoundary.startSample,
                tracks: []
            )
        )
    }
}
struct SegmentedWriterCoordinatorTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private func makeSpyCoordinator(
        boundaries: [SegmentBoundary]
    ) throws -> (SegmentedWriterCoordinator, T7SinkRegistry) {
        let registry = T7SinkRegistry()
        let coordinator = try SegmentedWriterCoordinator(boundaries: boundaries) { boundary in
            registry.makeSink(for: boundary)
        }
        return (coordinator, registry)
    }
    private func makeRealCoordinator(
        root: URL,
        staging: URL,
        boundaries: [SegmentBoundary],
        roles: Set<RecordingTrackRole>,
        sampleRate: Int = 8_000
    ) throws -> (SegmentedWriterCoordinator, T7LockedBox<[Int: RecordingCheckpointWriter]>) {
        let writers = T7LockedBox<[Int: RecordingCheckpointWriter]>([:])
        let capturedDate = fixedDate
        let coordinator = try SegmentedWriterCoordinator(boundaries: boundaries) { boundary in
            let writer = try RecordingCheckpointWriter(
                directory: staging,
                sessionRoot: root,
                segment: boundary,
                sampleRate: sampleRate,
                roles: roles,
                durability: SystemRecordingDurabilityBarrier(),
                now: { capturedDate },
                faults: T7FaultInjector()
            )
            var current = writers.value
            current[boundary.index] = writer
            writers.set(current)
            return writer
        }
        return (coordinator, writers)
    }
    private static let twoSegments = [
        SegmentBoundary(index: 0, startSample: 0, endSample: 960),
        SegmentBoundary(index: 1, startSample: 960, endSample: 1_920),
    ]
    @Test func boundaryUsesHalfOpenRule() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: Self.twoSegments)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 959, frameCount: 1, sampleRate: 8_000)
        )
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 960, frameCount: 1, sampleRate: 8_000)
        )
        let oldSink = try #require(registry.sink(at: 0))
        let newSink = try #require(registry.sink(at: 1))
        let oldRanges = await oldSink.appendedRanges(for: .mixed)
        let newRanges = await newSink.appendedRanges(for: .mixed)

        #expect(oldRanges == [SampleRange(startSample: 959, sampleCount: 1)])
        #expect(newRanges == [SampleRange(startSample: 960, sampleCount: 1)])
    }

    @Test func crossingBlockSplitsExactlyAndConservesFrames() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: Self.twoSegments)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 960, sampleRate: 8_000)
        )

        let oldSink = try #require(registry.sink(at: 0))
        let newSink = try #require(registry.sink(at: 1))
        let oldRanges = await oldSink.appendedRanges(for: .mixed)
        let newRanges = await newSink.appendedRanges(for: .mixed)

        #expect(oldRanges == [SampleRange(startSample: 480, sampleCount: 480)])
        #expect(newRanges == [SampleRange(startSample: 960, sampleCount: 480)])
        let oldFinishes = await oldSink.finishCount
        let newFinishes = await newSink.finishCount
        #expect(oldFinishes == 0)
        #expect(newFinishes == 0)
    }

    @Test func lateRolePrefixAfterCrossingStillLandsInOldSegment() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: Self.twoSegments)
        let crossing = T7TestSupport.block(
            role: .mixed,
            startSample: 0,
            frameCount: 1_440,
            sampleRate: 8_000
        )
        try await coordinator.append(crossing)
        try await coordinator.append(
            T7TestSupport.block(role: .system, startSample: 0, frameCount: 1_440, sampleRate: 8_000)
        )

        let oldSink = try #require(registry.sink(at: 0))
        let finishesBeforeClose = await oldSink.finishCount
        #expect(finishesBeforeClose == 0)
        let set = try await coordinator.closeSegment(at: 0)
        #expect(set.segmentIndex == 0)
        #expect(set.checkpoints.count == 1)
        #expect(set.checkpoints[0].range == SampleRange(startSample: 0, sampleCount: 960))
        let mixedRanges = await oldSink.appendedRanges(for: .mixed)
        let systemRanges = await oldSink.appendedRanges(for: .system)
        #expect(mixedRanges == [SampleRange(startSample: 0, sampleCount: 960)])
        #expect(systemRanges == [SampleRange(startSample: 0, sampleCount: 960)])
    }

    @Test func customTableIsUsedNot3540Formula() async throws {
        let custom = [
            SegmentBoundary(index: 0, startSample: 0, endSample: 100),
            SegmentBoundary(index: 1, startSample: 100, endSample: 200),
        ]
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: custom)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 150, sampleRate: 8_000)
        )

        #expect(registry.createdBoundaries == custom)
        #expect(registry.createdBoundaries.allSatisfy { $0.endSample != RecordingSegmentPolicy.maximumSegmentSamples })
        let oldSink = try #require(registry.sink(at: 0))
        let newSink = try #require(registry.sink(at: 1))
        let oldRanges = await oldSink.appendedRanges(for: .mixed)
        let newRanges = await newSink.appendedRanges(for: .mixed)
        #expect(oldRanges == [SampleRange(startSample: 0, sampleCount: 100)])
        #expect(newRanges == [SampleRange(startSample: 100, sampleCount: 50)])
    }

    @Test func commitCheckpointDoesNotDrainYoungerSink() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: Self.twoSegments)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 960, sampleRate: 8_000)
        )
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 960, frameCount: 240, sampleRate: 8_000)
        )

        let commit = try await coordinator.commitCheckpoint()
        #expect(commit.segmentIndex == 0)
        #expect(commit.range == SampleRange(startSample: 0, sampleCount: 960))

        let oldSink = try #require(registry.sink(at: 0))
        let newSink = try #require(registry.sink(at: 1))
        let oldCommits = await oldSink.commitCount
        let newCommits = await newSink.commitCount
        #expect(oldCommits == 1)
        #expect(newCommits == 0)

        let batch = try await coordinator.commitAvailableCheckpoints()
        #expect(batch.map(\.segmentIndex) == [1])
        #expect(batch.first?.range == SampleRange(startSample: 960, sampleCount: 240))
    }

    @Test func commitAvailableCheckpointsReturnsAllOpenSinksInOrder() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: Self.twoSegments)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000)
        )
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 960, frameCount: 480, sampleRate: 8_000)
        )

        let first = try await coordinator.commitAvailableCheckpoints()
        #expect(first.map(\.segmentIndex) == [0, 1])
        #expect(first[0].range == SampleRange(startSample: 0, sampleCount: 960))
        #expect(first[1].range == SampleRange(startSample: 960, sampleCount: 480))
        #expect(Set(first.map(\.checkpointID)).count == 2)

        let second = try await coordinator.commitAvailableCheckpoints()
        #expect(second.isEmpty)
        let oldSink = try #require(registry.sink(at: 0))
        let newSink = try #require(registry.sink(at: 1))
        let oldCommits = await oldSink.commitCount
        let newCommits = await newSink.commitCount
        #expect(oldCommits == 2)
        #expect(newCommits == 2)
    }

    @Test func failedBatchKeepsOlderDurableCommitDeliverable() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: Self.twoSegments)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 960, sampleRate: 8_000)
        )
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 960, frameCount: 240, sampleRate: 8_000)
        )
        let younger = try #require(registry.sink(at: 1))
        await younger.setFailCommitCount(1)

        await #expect(throws: RecordingCheckpointError.trackRangesDoNotMatch) {
            _ = try await coordinator.commitAvailableCheckpoints()
        }

        let retry = try await coordinator.commitAvailableCheckpoints()
        #expect(retry.map(\.segmentIndex) == [0, 1])
        #expect(retry.first?.range == SampleRange(startSample: 0, sampleCount: 960))
        #expect(retry.dropFirst().first?.range == SampleRange(startSample: 960, sampleCount: 240))
        #expect(Set(retry.map(\.checkpointID)).count == 2)

        let third = try await coordinator.commitAvailableCheckpoints()
        #expect(third.isEmpty)
    }

    @Test func closeSegmentSetHasEveryCheckpointOnce() async throws {
        let (coordinator, _) = try makeSpyCoordinator(boundaries: [Self.twoSegments[0]])
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000)
        )
        _ = try await coordinator.commitCheckpoint()
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )

        let set = try await coordinator.closeSegment(at: 0)
        #expect(set.checkpoints.count == 2)
        #expect(
            set.checkpoints.map(\.range) == [
                SampleRange(startSample: 0, sampleCount: 480),
                SampleRange(startSample: 480, sampleCount: 480),
            ])
        #expect(Set(set.checkpoints.map(\.checkpointID)).count == 2)
    }

    @Test func closeSegmentIsIdempotent() async throws {
        let (coordinator, _) = try makeSpyCoordinator(boundaries: [Self.twoSegments[0]])
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 960, sampleRate: 8_000)
        )

        let first = try await coordinator.closeSegment(at: 0)
        let second = try await coordinator.closeSegment(at: 0)
        #expect(first == second)

        await #expect(throws: RecordingCheckpointError.segmentClosed) {
            try await coordinator.append(
                T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000)
            )
        }
    }

    @Test func closeBeforeSegmentEndFailsWithSegmentIncomplete() async throws {
        let (coordinator, _) = try makeSpyCoordinator(boundaries: [Self.twoSegments[0]])
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000)
        )

        await #expect(
            throws: RecordingCheckpointError.segmentIncomplete(expectedEnd: 960, actualEnd: 480)
        ) {
            _ = try await coordinator.closeSegment(at: 0)
        }

        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480, sampleRate: 8_000)
        )
        let set = try await coordinator.closeSegment(at: 0)
        #expect(set.checkpoints.count == 1)
        #expect(set.checkpoints[0].range == SampleRange(startSample: 0, sampleCount: 960))
    }

    @Test func finalShortSegmentClosesWithActualEnd() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let (coordinator, _) = try makeRealCoordinator(
            root: root,
            staging: staging,
            boundaries: [Self.twoSegments[0]],
            roles: [.mixed]
        )
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 100, sampleRate: 8_000)
        )

        let bundle = try await coordinator.closeSegmentBundle(at: 0, isFinal: true)
        #expect(bundle.coverage.segmentEndSample == 100)
        #expect(bundle.checkpoints.checkpoints.count == 1)
        #expect(bundle.checkpoints.checkpoints[0].range == SampleRange(startSample: 0, sampleCount: 100))
    }

    @Test func failedSinkYieldsNoSetAndRetainsFiles() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: [Self.twoSegments[0]])
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 960, sampleRate: 8_000)
        )
        let sink = try #require(registry.sink(at: 0))
        await sink.setFailFinishCount(1)

        await #expect(throws: RecordingCheckpointError.writeFailed(role: nil, reason: "injectedFinishFailure")) {
            _ = try await coordinator.closeSegment(at: 0)
        }

        let set = try await coordinator.closeSegment(at: 0)
        #expect(set.checkpoints.count == 1)
        let repeated = try await coordinator.closeSegment(at: 0)
        #expect(repeated == set)
        let finishCount = await sink.finishCount
        #expect(finishCount == 2)
    }

    @Test func timeConservationAcrossThreeShortSegments() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let boundaries = [
            SegmentBoundary(index: 0, startSample: 0, endSample: 100),
            SegmentBoundary(index: 1, startSample: 100, endSample: 200),
            SegmentBoundary(index: 2, startSample: 200, endSample: 300),
        ]
        let (coordinator, writers) = try makeRealCoordinator(
            root: root,
            staging: staging,
            boundaries: boundaries,
            roles: [.mixed]
        )
        for index in 0..<3 {
            try await coordinator.append(
                T7TestSupport.block(
                    role: .mixed,
                    startSample: Int64(index * 100),
                    frameCount: 100,
                    sampleRate: 8_000
                )
            )
        }

        let commits = try await coordinator.commitAvailableCheckpoints()
        #expect(commits.map(\.segmentIndex) == [0, 1, 2])
        #expect(
            commits.map(\.range) == [
                SampleRange(startSample: 0, sampleCount: 100),
                SampleRange(startSample: 100, sampleCount: 100),
                SampleRange(startSample: 200, sampleCount: 100),
            ])
        #expect(commits.map { $0.range.startSample + $0.range.sampleCount } == [100, 200, 300])

        for index in 0..<2 {
            let set = try await coordinator.closeSegment(at: index)
            #expect(set.checkpoints.count == 1)
        }
        let final = try await coordinator.closeSegment(at: 2, isFinal: true)
        #expect(final.checkpoints.count == 1)

        let writerMap = writers.value
        for index in 0..<3 {
            let writer = try #require(writerMap[index])
            let stats = await writer.statistics()
            let committed = try #require(stats.committedFramesByRole[.mixed])
            let appended = try #require(stats.appendedFramesByRole[.mixed])
            let silence = try #require(stats.writerSynthesizedSilenceFramesByRole[.mixed])
            #expect(committed == appended + silence)
            #expect(committed == 100)
        }
    }

    @Test func nextSinkPreparedBeforeBoundary() async throws {
        let (coordinator, registry) = try makeSpyCoordinator(boundaries: Self.twoSegments)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 960, sampleRate: 8_000)
        )

        let events = registry.events.events
        let createOld = try #require(events.firstIndex(of: "create-1"))
        let appendOld = try #require(events.firstIndex(of: "append-0-480-480"))
        let appendNew = try #require(events.firstIndex(of: "append-1-960-480"))
        #expect(createOld < appendOld)
        #expect(createOld < appendNew)
        #expect(createOld == 1)
    }

    @Test func streamDeliversEachClosedSetOnce() async throws {
        let custom = [
            SegmentBoundary(index: 0, startSample: 0, endSample: 100),
            SegmentBoundary(index: 1, startSample: 100, endSample: 200),
        ]
        let (coordinator, _) = try makeSpyCoordinator(boundaries: custom)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 100, sampleRate: 8_000)
        )
        _ = try await coordinator.closeSegment(at: 0)
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 100, frameCount: 100, sampleRate: 8_000)
        )
        _ = try await coordinator.closeSegment(at: 1, isFinal: true)

        let stream = await coordinator.makeClosedSegmentStream()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        #expect(first?.segmentIndex == 0)
        #expect(second?.segmentIndex == 1)
        #expect(first?.checkpoints.count == 1)
        #expect(second?.checkpoints.count == 1)
        #expect(first?.checkpoints[0].checkpointID != second?.checkpoints[0].checkpointID)
    }

    @Test func concurrentAppendIsRejectedOrSerialized() async throws {
        let gate = T7GateSink(boundary: Self.twoSegments[0])
        let coordinator = try SegmentedWriterCoordinator(boundaries: [Self.twoSegments[0]]) { _ in gate }

        let first = Task {
            try await coordinator.append(
                T7TestSupport.block(role: .mixed, startSample: 0, frameCount: 480, sampleRate: 8_000)
            )
        }
        await gate.waitUntilAppendEntered()

        let error = await T7TestSupport.captureError {
            try await coordinator.append(
                T7TestSupport.block(role: .mixed, startSample: 480, frameCount: 480, sampleRate: 8_000)
            )
        }
        #expect(error == RecordingCheckpointError.writeFailed(role: nil, reason: "concurrentAccess"))
        let commitError = await T7TestSupport.captureError {
            _ = try await coordinator.commitCheckpoint()
        }
        #expect(commitError == RecordingCheckpointError.writeFailed(role: nil, reason: "concurrentAccess"))

        await gate.releaseAppend()
        try await first.value
    }

    @Test func coverageCarriesFixedFormatAfterRoleCloses() async throws {
        let root = try T7TestSupport.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try T7TestSupport.makeStaging(in: root)
        let (coordinator, _) = try makeRealCoordinator(
            root: root,
            staging: staging,
            boundaries: [SegmentBoundary(index: 0, startSample: 0, endSample: 200)],
            roles: [.system, .mixed]
        )
        try await coordinator.append(
            T7TestSupport.block(
                role: .system,
                startSample: 0,
                frameCount: 100,
                sampleRate: 8_000,
                channelCount: 2,
                values: [0.5, -0.25]
            )
        )
        _ = try await coordinator.commitCheckpoint()
        try await coordinator.append(
            T7TestSupport.block(role: .mixed, startSample: 100, frameCount: 100, sampleRate: 8_000)
        )
        _ = try await coordinator.commitCheckpoint()

        let bundle = try await coordinator.closeSegmentBundle(at: 0)
        #expect(bundle.coverage.segmentEndSample == 200)
        let system = try #require(bundle.coverage.tracks.first { $0.role == "system" })
        #expect(system.sampleRate == 8_000)
        #expect(system.channelCount == 2)
        #expect(system.wasActive)
        #expect(system.missingRanges == [RecordingSampleRange(startSample: 100, sampleCount: 100)])
        let mixed = try #require(bundle.coverage.tracks.first { $0.role == "mixed" })
        #expect(mixed.sampleRate == 8_000)
        #expect(mixed.channelCount == 1)
        #expect(mixed.missingRanges == [RecordingSampleRange(startSample: 0, sampleCount: 100)])
    }
}
