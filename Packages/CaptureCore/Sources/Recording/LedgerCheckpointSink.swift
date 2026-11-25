import Foundation

private struct PendingTick {
    let range: SampleRange
    var blocks: [RecordingTrackRole: AudioPCMBlock]
    var deliveredRoles: Set<RecordingTrackRole> = []
}

/// The durable checkpoint facts a finished session reports.
///
/// Named fields replace the previous three-member tuple so call sites read
/// `facts.committedAt` instead of a positional element.
struct RecordingCheckpointFacts: Sendable {
    let sampleEnd: Int64
    let committedAt: Date?
    let publishedCount: Int
}

/// Bridges T1's append/commit sink to T7's segmented coordinator and T9's journal.
public actor LedgerCheckpointSink: AudioCheckpointSink {
    private let coordinator: SegmentedWriterCoordinator
    private let ledger: RecordingSessionLedger
    private let spaceGate: (any RecordingSpaceGating)?
    private let onSegmentClosed: @Sendable (Int, UUID?) -> Void
    private let onSpaceStatus: @Sendable (RecordingSpaceStatus) async -> Void
    private var pendingTick: PendingTick?
    private var pendingJournal: [CheckpointCommit] = []
    private var lastDurableCommit: CheckpointCommit?
    private var lastSampleEnd: Int64 = 0
    private var nextSegmentToClose = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sealBacklogBytesBySegment: [Int: Int64] = [:]

    public init(
        coordinator: SegmentedWriterCoordinator,
        ledger: RecordingSessionLedger,
        spaceGate: (any RecordingSpaceGating)? = nil
    ) {
        self.coordinator = coordinator
        self.ledger = ledger
        self.spaceGate = spaceGate
        self.onSegmentClosed = { _, _ in }
        self.onSpaceStatus = { _ in }
    }

    init(
        coordinator: SegmentedWriterCoordinator,
        ledger: RecordingSessionLedger,
        spaceGate: (any RecordingSpaceGating)?,
        onSegmentClosed: @escaping @Sendable (Int, UUID?) -> Void,
        onSpaceStatus: @escaping @Sendable (RecordingSpaceStatus) async -> Void
    ) {
        self.coordinator = coordinator
        self.ledger = ledger
        self.spaceGate = spaceGate
        self.onSegmentClosed = onSegmentClosed
        self.onSpaceStatus = onSpaceStatus
    }

    public func append(_ block: AudioPCMBlock) async throws {
        await acquire()
        defer { release() }
        guard block.frameCount > 0, block.range.sampleCount == Int64(block.frameCount),
            block.sampleRate == 48_000, block.channelCount == block.channels.count,
            block.channels.allSatisfy({ $0.count == block.frameCount }),
            block.role == .mixed || block.role == .system || block.role == .microphone
        else { throw RecordingCheckpointError.incompatibleFormat(role: block.role) }
        if var current = pendingTick {
            if current.range == block.range {
                guard current.blocks[block.role] == nil else {
                    throw RecordingCheckpointError.rangeOverlap(
                        expectedStart: block.range.startSample, actualStart: block.range.startSample
                    )
                }
                current.blocks[block.role] = block
                pendingTick = current
                return
            }
            let currentEnd = current.range.startSample + current.range.sampleCount
            guard block.range.startSample == currentEnd else {
                throw RecordingCheckpointError.nonContiguousRange(
                    expectedStart: currentEnd, actualStart: block.range.startSample
                )
            }
            pendingTick = current
            try await flushPendingTick()
        } else if block.range.startSample != lastSampleEnd {
            guard lastSampleEnd == 0, block.range.startSample == 0 else {
                throw RecordingCheckpointError.nonContiguousRange(
                    expectedStart: lastSampleEnd, actualStart: block.range.startSample
                )
            }
        }
        pendingTick = PendingTick(range: block.range, blocks: [block.role: block])
    }

    /// Engine stop path: flushes the final complete tick group and journals all commits.
    public func commitCheckpoint() async throws -> CheckpointCommit {
        await acquire()
        defer { release() }
        try await flushPendingTick()
        try await commitCoordinatorBatch()
        guard let lastDurableCommit else { throw RecordingCheckpointError.emptyCheckpoint }
        return lastDurableCommit
    }

    /// Monotonic T9 cadence path: commits only tick groups already closed by a later range.
    func commitReadyCheckpoints() async throws -> [CheckpointCommit] {
        await acquire()
        defer { release() }
        return try await commitCoordinatorBatch()
    }

    func finishTail() async throws {
        await acquire()
        defer { release() }
        try await flushPendingTick()
        try await commitCoordinatorBatch()
        guard lastSampleEnd > 0 else { return }
        let plan = AudioSegmentPlan()
        let index = Int((lastSampleEnd - 1) / plan.maximumSegmentSamples)
        guard index >= nextSegmentToClose else { return }
        let bundle = try await coordinator.closeSegmentBundle(at: index, isFinal: true)
        try await journal(bundle.checkpoints.checkpoints)
        try await ledger.recordClosedSegment(bundle)
        nextSegmentToClose = index + 1
        sealBacklogBytesBySegment[index] = Self.byteCount(bundle.checkpoints.checkpoints)
        onSegmentClosed(index, bundle.checkpoints.checkpoints.last?.checkpointID)
    }

    func retryPendingJournal() async throws {
        await acquire()
        defer { release() }
        try await drainPendingJournal()
    }

    func sealBacklogBytes() -> Int64 {
        sealBacklogBytesBySegment.values.reduce(0, +)
    }

    func sealFinished(segmentIndex: Int) async {
        await acquire()
        defer { release() }
        sealBacklogBytesBySegment[segmentIndex] = nil
        await spaceGate?.sealFinished(segmentIndex: segmentIndex)
    }

    func checkpointFacts() async -> RecordingCheckpointFacts {
        let facts = await ledger.progressFacts()
        return RecordingCheckpointFacts(
            sampleEnd: facts.sampleEnd,
            committedAt: facts.committedAt,
            publishedCount: facts.publishedCount
        )
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func flushPendingTick() async throws {
        guard var tick = pendingTick else { return }
        for role in [RecordingTrackRole.mixed, .system, .microphone] {
            guard let block = tick.blocks[role], !tick.deliveredRoles.contains(role) else { continue }
            try await coordinator.append(block)
            tick.deliveredRoles.insert(role)
            pendingTick = tick
        }
        pendingTick = nil
        lastSampleEnd = tick.range.startSample + tick.range.sampleCount
        try await closeCompletedSegments(through: lastSampleEnd)
    }

    private func closeCompletedSegments(through sampleEnd: Int64) async throws {
        let plan = AudioSegmentPlan()
        while nextSegmentToClose < Int.max {
            let start = Int64(nextSegmentToClose).multipliedReportingOverflow(by: plan.maximumSegmentSamples)
            guard !start.overflow else { throw RecordingCheckpointError.invalidConfiguration }
            let boundary = try plan.boundary(containing: start.partialValue)
            guard boundary.endSample <= sampleEnd else { return }
            let bundle = try await coordinator.closeSegmentBundle(at: boundary.index)
            try await journal(bundle.checkpoints.checkpoints)
            try await ledger.recordClosedSegment(bundle)
            sealBacklogBytesBySegment[boundary.index] = Self.byteCount(bundle.checkpoints.checkpoints)
            nextSegmentToClose = boundary.index + 1
            onSegmentClosed(boundary.index, bundle.checkpoints.checkpoints.last?.checkpointID)
        }
    }

    private func commitCoordinatorBatch() async throws -> [CheckpointCommit] {
        try await drainPendingJournal()
        let commits = try await coordinator.commitAvailableCheckpoints()
        pendingJournal.append(contentsOf: commits)
        try await drainPendingJournal()
        return commits
    }

    private func journal(_ commits: [CheckpointCommit]) async throws {
        pendingJournal.append(contentsOf: commits)
        try await drainPendingJournal()
    }

    private func drainPendingJournal() async throws {
        while let commit = pendingJournal.first {
            try await ledger.commit(commit)
            pendingJournal.removeFirst()
            lastDurableCommit = commit
            if let spaceGate {
                let status = await spaceGate.checkpointCommitted(commit, backlogBytes: sealBacklogBytes())
                await onSpaceStatus(status)
            }
        }
    }

    private static func byteCount(_ commits: [CheckpointCommit]) -> Int64 {
        commits.reduce(into: Int64(0)) { total, commit in
            for url in commit.trackURLs.values {
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber {
                    total += size.int64Value
                }
            }
        }
    }
}
