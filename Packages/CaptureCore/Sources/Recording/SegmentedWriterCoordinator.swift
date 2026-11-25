import Foundation

/// Routes global 48 kHz sample blocks to per-segment sinks.
///
/// The coordinator splits a block exactly at actual segment boundaries, keeps
/// the older sink writable after a crossing so late role prefixes still land in
/// it, and closes segments only when asked. It is the single writer for its
/// sinks and rejects reentrant calls instead of interleaving a chunk.
public actor SegmentedWriterCoordinator: AudioCheckpointSink {
    private struct Part {
        let boundary: SegmentBoundary
        let block: AudioPCMBlock
    }

    private let plan: (any RecordingSegmentPlan)?
    private let table: [SegmentBoundary]?
    private let tableByIndex: [Int: SegmentBoundary]
    private let sinkFactory: @Sendable (SegmentBoundary) throws -> any SegmentCheckpointSink

    private var sinks: [Int: any SegmentCheckpointSink] = [:]
    private var boundaryCache: [Int: SegmentBoundary] = [:]
    private var expectedEndByIndex: [Int: Int64] = [:]
    private var closedSets: [Int: SegmentCheckpointSet] = [:]
    private var closedBundles: [Int: RecordingSegmentCheckpointBundle] = [:]
    private var closedOrder: [Int] = []
    private var deliveredCheckpointIDs: Set<UUID> = []
    private var lastCommit: CheckpointCommit?
    private var continuations: [UUID: AsyncStream<SegmentCheckpointSet>.Continuation] = [:]
    private var sessionSampleRate: Int?
    private var isBusy = false

    /// Creates a coordinator driven by a segment plan.
    ///
    /// - Parameters:
    ///   - plan: Resolves boundaries on demand.
    ///   - sinkFactory: Creates one sink per boundary; called before its suffix is written.
    /// - Throws: ``RecordingCheckpointError/invalidConfiguration`` when the plan is unusable.
    public init(
        plan: any RecordingSegmentPlan,
        sinkFactory: @escaping @Sendable (SegmentBoundary) throws -> any SegmentCheckpointSink
    ) throws {
        self.plan = plan
        table = nil
        tableByIndex = [:]
        self.sinkFactory = sinkFactory
    }

    /// Creates a coordinator from an explicit contiguous boundary table.
    ///
    /// The table is sorted by sample start. Indexes must increase in the same
    /// order and every segment must contain at least one sample.
    ///
    /// - Parameters:
    ///   - boundaries: Contiguous half-open boundaries.
    ///   - sinkFactory: Creates one sink per boundary; called before its suffix is written.
    /// - Throws: ``RecordingCheckpointError/invalidConfiguration`` when the table is not contiguous.
    public init(
        boundaries: [SegmentBoundary],
        sinkFactory: @escaping @Sendable (SegmentBoundary) throws -> any SegmentCheckpointSink
    ) throws {
        plan = nil
        let validated = try Self.validated(boundaries)
        table = validated
        tableByIndex = Dictionary(uniqueKeysWithValues: validated.map { ($0.index, $0) })
        self.sinkFactory = sinkFactory
    }

    /// Appends a block using its own range start for routing.
    ///
    /// - Parameter block: The block to route; its range is on the session grid.
    /// - Throws: ``RecordingCheckpointError`` when the block is invalid or a sink fails.
    public func append(_ block: AudioPCMBlock) async throws {
        try await append(block, at: block.range.startSample)
    }

    /// Appends a block at an explicit session-global first sample.
    ///
    /// - Parameters:
    ///   - block: The block to route; its frame count must equal its range count.
    ///   - globalSample: 48 kHz session-global index of the block's first frame.
    /// - Throws: ``RecordingCheckpointError`` when the block is invalid or a sink fails.
    public func append(_ block: AudioPCMBlock, at globalSample: Int64) async throws {
        try beginOperation()
        defer { isBusy = false }
        try validate(block)
        let parts = try split(block: block, at: globalSample)

        var destinations: [(sink: any SegmentCheckpointSink, part: Part)] = []
        for part in parts {
            if closedSets[part.boundary.index] != nil {
                throw RecordingCheckpointError.segmentClosed
            }
            let sink = try resolvedSink(for: part.boundary)
            destinations.append((sink, part))
        }
        for destination in destinations {
            if closedSets[destination.part.boundary.index] != nil {
                throw RecordingCheckpointError.segmentClosed
            }
            try await destination.sink.append(destination.part.block)
            let partEnd =
                destination.part.block.range.startSample
                + destination.part.block.range.sampleCount
            expectedEndByIndex[destination.part.boundary.index] = max(
                expectedEndByIndex[destination.part.boundary.index] ?? destination.part.boundary.startSample,
                partEnd
            )
        }
        if sessionSampleRate == nil {
            sessionSampleRate = block.sampleRate
        }
    }

    /// Commits only the oldest open sink's current chunk.
    ///
    /// Younger sinks are untouched. If the oldest sink has no new samples, its
    /// previous commit is returned; when no commit exists the call throws
    /// ``RecordingCheckpointError/emptyCheckpoint``.
    ///
    /// - Returns: The commit produced by the oldest open sink.
    /// - Throws: ``RecordingCheckpointError`` when the commit fails.
    public func commitCheckpoint() async throws -> CheckpointCommit {
        try beginOperation()
        defer { isBusy = false }
        let indexes = openIndexes()
        guard let oldest = indexes.first, let sink = sinks[oldest] else {
            if let lastCommit {
                return lastCommit
            }
            throw RecordingCheckpointError.emptyCheckpoint
        }
        let commit = try await sink.commitCheckpoint()
        deliveredCheckpointIDs.insert(commit.checkpointID)
        lastCommit = commit
        return commit
    }

    /// Commits every open sink's current chunk in segment order.
    ///
    /// Sinks without new samples are skipped. The returned array contains only
    /// commits not previously delivered, so repeating the call returns an empty
    /// array.
    ///
    /// - Returns: New commits ordered by segment index.
    /// - Throws: ``RecordingCheckpointError`` when any sink fails to commit.
    public func commitAvailableCheckpoints() async throws -> [CheckpointCommit] {
        try beginOperation()
        defer { isBusy = false }
        var commits: [CheckpointCommit] = []
        for index in openIndexes() {
            guard let sink = sinks[index] else {
                continue
            }
            do {
                let commit = try await sink.commitCheckpoint()
                if !deliveredCheckpointIDs.contains(commit.checkpointID),
                    !commits.contains(where: { $0.checkpointID == commit.checkpointID })
                {
                    commits.append(commit)
                }
            } catch let error as RecordingCheckpointError {
                if case .emptyCheckpoint = error {
                    continue
                }
                throw error
            }
        }
        deliveredCheckpointIDs.formUnion(commits.map(\.checkpointID))
        if let newest = commits.last {
            lastCommit = newest
        }
        return commits
    }

    /// Closes one segment and returns its checkpoint set.
    ///
    /// - Parameters:
    ///   - index: Zero-based segment index.
    ///   - isFinal: Whether a short final segment may end before its boundary end.
    /// - Returns: The segment's committed checkpoint set.
    /// - Throws: ``RecordingCheckpointError`` when the segment is incomplete or a commit fails.
    public func closeSegment(at index: Int, isFinal: Bool = false) async throws -> SegmentCheckpointSet {
        try await closeSegmentBundle(at: index, isFinal: isFinal).checkpoints
    }

    /// Closes one segment and returns checkpoints plus coverage.
    ///
    /// - Parameters:
    ///   - index: Zero-based segment index.
    ///   - isFinal: Whether a short final segment may end before its boundary end.
    /// - Returns: The segment's checkpoints and coverage.
    /// - Throws: ``RecordingCheckpointError`` when the segment is incomplete or a commit fails.
    public func closeSegmentBundle(
        at index: Int,
        isFinal: Bool = false
    ) async throws -> RecordingSegmentCheckpointBundle {
        try beginOperation()
        defer { isBusy = false }
        if let bundle = closedBundles[index] {
            return bundle
        }
        let boundary = try boundary(at: index)
        if !isFinal {
            let actualEnd = expectedEndByIndex[index] ?? boundary.startSample
            guard actualEnd == boundary.endSample else {
                throw RecordingCheckpointError.segmentIncomplete(
                    expectedEnd: boundary.endSample,
                    actualEnd: actualEnd
                )
            }
        }
        let sink: any SegmentCheckpointSink
        if let existing = sinks[index] {
            sink = existing
        } else {
            sink = try resolvedSink(for: boundary)
        }
        let bundle = try await sink.finishSegmentBundle()
        guard bundle.checkpoints.segmentIndex == index else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        closedSets[index] = bundle.checkpoints
        closedBundles[index] = bundle
        closedOrder.append(index)
        for continuation in continuations.values {
            continuation.yield(bundle.checkpoints)
        }
        return bundle
    }

    /// Creates the single-consumer stream of closed segment sets.
    ///
    /// Sets closed before the stream is created are replayed in close order;
    /// each later close is delivered exactly once.
    ///
    /// - Returns: A stream of closed checkpoint sets.
    public func makeClosedSegmentStream() -> AsyncStream<SegmentCheckpointSet> {
        let (stream, continuation) = AsyncStream.makeStream(of: SegmentCheckpointSet.self)
        let identifier = UUID()
        continuations[identifier] = continuation
        for index in closedOrder {
            if let set = closedSets[index] {
                continuation.yield(set)
            }
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        return stream
    }

    private func beginOperation() throws {
        guard !isBusy else {
            throw RecordingCheckpointError.writeFailed(role: nil, reason: "concurrentAccess")
        }
        isBusy = true
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations[identifier] = nil
    }

    private func openIndexes() -> [Int] {
        sinks.keys.filter { closedSets[$0] == nil }.sorted()
    }

    private func validate(_ block: AudioPCMBlock) throws {
        guard block.frameCount > 0,
            Int64(block.frameCount) == block.range.sampleCount,
            block.sampleRate > 0,
            block.channelCount > 0,
            block.channelCount == block.channels.count,
            block.channels.allSatisfy({ $0.count == block.frameCount })
        else {
            throw RecordingCheckpointError.incompatibleFormat(role: block.role)
        }
        if let sessionSampleRate, sessionSampleRate != block.sampleRate {
            throw RecordingCheckpointError.incompatibleFormat(role: block.role)
        }
    }

    private func split(block: AudioPCMBlock, at globalSample: Int64) throws -> [Part] {
        var parts: [Part] = []
        var cursor = globalSample
        let end = globalSample + Int64(block.frameCount)
        var currentBoundary = try boundary(containing: cursor)
        while cursor < end {
            let partEnd = min(end, currentBoundary.endSample)
            guard partEnd > cursor else {
                throw RecordingCheckpointError.invalidConfiguration
            }
            let offset = Int(cursor - globalSample)
            let frameCount = Int(partEnd - cursor)
            let channels = block.channels.map { channel in
                Array(channel[offset..<(offset + frameCount)])
            }
            let partBlock = AudioPCMBlock(
                role: block.role,
                range: SampleRange(startSample: cursor, sampleCount: Int64(frameCount)),
                sampleRate: block.sampleRate,
                channelCount: block.channelCount,
                frameCount: frameCount,
                hostTime: block.hostTime,
                channels: channels,
                isSilence: block.isSilence
            )
            parts.append(Part(boundary: currentBoundary, block: partBlock))
            cursor = partEnd
            if cursor < end {
                currentBoundary = try boundary(after: currentBoundary)
            }
        }
        return parts
    }

    private func resolvedSink(for boundary: SegmentBoundary) throws -> any SegmentCheckpointSink {
        if let existing = sinks[boundary.index] {
            return existing
        }
        let sink = try sinkFactory(boundary)
        guard sink.segmentBoundary == boundary else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        sinks[boundary.index] = sink
        boundaryCache[boundary.index] = boundary
        return sink
    }

    private func boundary(containing sample: Int64) throws -> SegmentBoundary {
        if let table {
            guard let match = Self.boundary(in: table, containing: sample) else {
                throw RecordingCheckpointError.blockOutsideSegment
            }
            boundaryCache[match.index] = match
            return match
        }
        if let cached = boundaryCache.values.first(where: { sample >= $0.startSample && sample < $0.endSample }) {
            return cached
        }
        guard let plan else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        let match = try plan.boundary(containing: sample)
        guard sample >= match.startSample, sample < match.endSample else {
            throw RecordingCheckpointError.blockOutsideSegment
        }
        boundaryCache[match.index] = match
        return match
    }

    private func boundary(after current: SegmentBoundary) throws -> SegmentBoundary {
        if let table {
            guard let offset = table.firstIndex(where: { $0.index == current.index }),
                offset + 1 < table.count
            else {
                throw RecordingCheckpointError.blockOutsideSegment
            }
            let next = table[offset + 1]
            guard next.startSample == current.endSample else {
                throw RecordingCheckpointError.invalidConfiguration
            }
            boundaryCache[next.index] = next
            return next
        }
        guard let plan else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        let next = try plan.nextBoundary(after: current)
        guard next.startSample == current.endSample, next.index > current.index else {
            throw RecordingCheckpointError.invalidConfiguration
        }
        boundaryCache[next.index] = next
        return next
    }

    private func boundary(at index: Int) throws -> SegmentBoundary {
        if table != nil {
            guard let match = tableByIndex[index] else {
                throw RecordingCheckpointError.unknownSegment(index)
            }
            return match
        }
        if let cached = boundaryCache[index] {
            return cached
        }
        guard let plan else {
            throw RecordingCheckpointError.unknownSegment(index)
        }
        var current: SegmentBoundary
        if let earliest = boundaryCache.values.min(by: { $0.index < $1.index }), earliest.index <= index {
            current = earliest
        } else {
            current = try plan.boundary(containing: 0)
        }
        while current.index < index {
            current = try plan.nextBoundary(after: current)
        }
        guard current.index == index else {
            throw RecordingCheckpointError.unknownSegment(index)
        }
        boundaryCache[index] = current
        return current
    }

    private static func validated(_ boundaries: [SegmentBoundary]) throws -> [SegmentBoundary] {
        guard !boundaries.isEmpty else {
            return []
        }
        let sorted = boundaries.sorted { $0.startSample < $1.startSample }
        var seen: Set<Int> = []
        for (offset, boundary) in sorted.enumerated() {
            guard boundary.index >= 0,
                boundary.endSample > boundary.startSample,
                seen.insert(boundary.index).inserted
            else {
                throw RecordingCheckpointError.invalidConfiguration
            }
            if offset > 0 {
                guard sorted[offset - 1].endSample == boundary.startSample,
                    sorted[offset - 1].index < boundary.index
                else {
                    throw RecordingCheckpointError.invalidConfiguration
                }
            }
        }
        return sorted
    }

    private static func boundary(
        in boundaries: [SegmentBoundary],
        containing sample: Int64
    ) -> SegmentBoundary? {
        var low = 0
        var high = boundaries.count - 1
        var candidate: SegmentBoundary?
        while low <= high {
            let middle = (low + high) / 2
            if boundaries[middle].startSample <= sample {
                candidate = boundaries[middle]
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let candidate, sample < candidate.endSample else {
            return nil
        }
        return candidate
    }
}
