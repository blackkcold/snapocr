import Foundation
/// The reason a producer write was partially or completely rejected.
public enum RingDropReason: Sendable, Equatable {
    /// The ring and staging area could not hold the next frames.
    case overflow
    /// The producer wrote after the ring was closed or finished.
    case closed
    /// Another producer was already inside a write call.
    case reentrantProducer
    /// Another consumer was already inside a read call.
    case reentrantConsumer
    /// The input channel layout or frame count was invalid.
    case invalidFormat
    /// The host timestamp could not be represented without overflow.
    case invalidTimestamp
}
/// The result of one producer write.
public struct RingWriteResult: Sendable, Equatable {
    /// Frames copied into the ring or staging area.
    public let acceptedFrames: Int
    /// Frames rejected by this call.
    public let droppedFrames: Int
    /// Why frames were rejected, or `nil` when every frame was accepted.
    public let reason: RingDropReason?
    /// Creates a write result.
    public init(acceptedFrames: Int, droppedFrames: Int, reason: RingDropReason?) {
        self.acceptedFrames = acceptedFrames
        self.droppedFrames = droppedFrames
        self.reason = reason
    }
}
/// The reason a consumer read returned no block.
public enum RingReadReason: Sendable, Equatable {
    /// Another consumer was already inside a read call.
    case reentrantConsumer
    /// `maxFrames` was zero or negative.
    case invalidMaxFrames
}
/// The result of one consumer read.
public struct RingReadResult: Sendable {
    /// An owned block copied out of the ring, or `nil` when no frames are ready.
    public let block: AudioPCMBlock?
    /// Frames missing immediately before `block`; delivered exactly once.
    public let gapFrames: Int
    /// Whether the ring was closed and has no queued or staged frames left.
    public let isClosedAndEmpty: Bool
    /// Why no block was returned, or `nil` for a normal empty read.
    public let reason: RingReadReason?
    /// Creates a read result.
    public init(
        block: AudioPCMBlock?,
        gapFrames: Int,
        isClosedAndEmpty: Bool,
        reason: RingReadReason?
    ) {
        self.block = block
        self.gapFrames = gapFrames
        self.isClosedAndEmpty = isClosedAndEmpty
        self.reason = reason
    }
}
/// The result of finalizing the producer side.
public struct RingFinalizeResult: Sendable, Equatable {
    /// Staging frames published as a final short slot.
    public let flushedFrames: Int
    /// Staging frames still retained because the slot table was full.
    public let retainedStagingFrames: Int
    /// Whether a producer was still inside a write or finalize call.
    public let producerStillActive: Bool
    /// Creates a finalize result.
    public init(flushedFrames: Int, retainedStagingFrames: Int, producerStillActive: Bool) {
        self.flushedFrames = flushedFrames
        self.retainedStagingFrames = retainedStagingFrames
        self.producerStillActive = producerStillActive
    }
}
/// A snapshot of ring counters.
/// The fields are read independently and may not describe one exact instant.
/// Reading stats never mutates shared non-atomic state.
public struct RingStats: Sendable, Equatable {
    /// Frames accepted since construction.
    public let acceptedFrames: Int64
    /// Frames rejected because of overflow or invalid input.
    public let droppedFrames: Int64
    /// Dropped frames owed to the timeline as a gap.
    public let gapFrames: Int64
    /// Frames currently held in the producer staging area.
    public let stagingFrames: Int
    /// Highest accepted producer ownership depth.
    public let producerMaxDepth: Int
    /// Highest accepted consumer ownership depth.
    public let consumerMaxDepth: Int
    /// Rejected overlapping producer or consumer calls.
    public let reentrantRejects: Int
    /// Most recent gate-protected producer drop; reentrant rejections are
    /// visible in ``reentrantRejects`` and each ``RingWriteResult/reason``.
    public let lastDropReason: RingDropReason?
    /// Creates a stats snapshot.
    public init(
        acceptedFrames: Int64,
        droppedFrames: Int64,
        gapFrames: Int64,
        stagingFrames: Int,
        producerMaxDepth: Int,
        consumerMaxDepth: Int,
        reentrantRejects: Int,
        lastDropReason: RingDropReason?
    ) {
        self.acceptedFrames = acceptedFrames
        self.droppedFrames = droppedFrames
        self.gapFrames = gapFrames
        self.stagingFrames = stagingFrames
        self.producerMaxDepth = producerMaxDepth
        self.consumerMaxDepth = consumerMaxDepth
        self.reentrantRejects = reentrantRejects
        self.lastDropReason = lastDropReason
    }
}
/// A configuration error for ``AudioSourceRingBuffer``.
public enum AudioRingConfigurationError: Error, Equatable {
    /// The sample rate was zero, negative, or unreasonably large.
    case invalidSampleRate
    /// The channel count was not one or two.
    case invalidChannelCount
    /// The capacity was not finite or outside `0.05...2.0` seconds.
    case invalidCapacity
    /// The host timebase was zero or not representable as `Int64`.
    case invalidHostTimebase
}
private struct AudioRingSlot {
    var frameCount = 0
    var hostTime: UInt64 = 0
    var rangeStart: Int64 = 0
    var gapBefore = 0
}
/// A bounded single-producer/single-consumer ring of owned audio slots.
/// ## Ownership
/// Production and consumption are each guarded by an acquire-release ownership
/// gate. A gate handoff makes the previous owner's private cursor and staging
/// state visible to the next owner; a rejected overlapping call never mutates
/// the active owner's state.
/// The producer publishes only after filling a slot; the consumer reads with
/// acquire ordering and releases the slot only after copying it. No write
/// overwrites an unread slot.
/// ``requestClose()`` only sets an atomic flag and never touches staging.
/// ``finishProducing()`` publishes the final short slot after the producer joins.
/// ``isClosedAndEmpty`` requires a drained, staging-free, inactive-producer state.
/// `@unchecked Sendable` is backed by the SPSC, atomic, and close proof above;
/// the annotation itself is not the proof.
public final class AudioSourceRingBuffer: @unchecked Sendable {
    private let role: RecordingTrackRole
    private let sampleRate: Int
    private let channelCount: Int
    private let hostTicksPerSecond: UInt64
    private let slotCapacity: Int
    /// Frames the ring budget allows, including staging.
    public let capacityFrames: Int
    /// Nominal frames per slot, one hundredth of the sample rate.
    public let slotFrameCount: Int
    private let writeSequence: any AudioAtomicCounter
    private let readSequence: any AudioAtomicCounter
    private let producerGate: AudioOwnershipGate
    private let consumerGate: AudioOwnershipGate
    private let closedFlag: any AudioAtomicCounter
    private let finishedFlag: any AudioAtomicCounter
    private let unassignedGap: any AudioAtomicCounter
    private let acceptedCounter: any AudioAtomicCounter
    private let droppedCounter: any AudioAtomicCounter
    private let gapCounter: any AudioAtomicCounter
    private let reentrantCounter: any AudioAtomicCounter
    private let stagingCounter: any AudioAtomicCounter
    private let lastDropCode: any AudioAtomicCounter
    private let slotMetadata: UnsafeMutablePointer<AudioRingSlot>
    private let slotSamples: UnsafeMutablePointer<Float>
    private var publishedSlotCount: Int64 = 0
    private var nextWriteSlot = 0
    private var stagingChannels: [[Float]]
    private var stagingCount = 0
    private var stagingHostTime: UInt64 = 0
    private var stagingRangeStart: Int64 = 0
    private var stagingGapBefore = 0
    private var stagingSealed = false
    private var nextSourceFrame: Int64 = 0
    private var gapCarry = 0
    private var nextReadSequence: Int64 = 0
    private var nextReadSlot = 0
    private var partialSlotIndex = 0
    private var partialSlotOffset = 0
    private var partialSlotRemaining = 0
    private var pendingSlotGap = 0
    private var terminalGapDelivered = false
    /// Creates a ring with the production atomic backend; invalid configuration throws.
    public convenience init(
        role: RecordingTrackRole,
        sampleRate: Int,
        channelCount: Int,
        hostTicksPerSecond: UInt64,
        capacitySeconds: Double = 2.0
    ) throws {
        try self.init(
            role: role,
            sampleRate: sampleRate,
            channelCount: channelCount,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: capacitySeconds,
            atomicMode: .automatic
        )
    }
    internal init(
        role: RecordingTrackRole,
        sampleRate: Int,
        channelCount: Int,
        hostTicksPerSecond: UInt64,
        capacitySeconds: Double = 2.0,
        atomicMode: AudioAtomicBackendMode,
        producerGate: AudioOwnershipGate? = nil,
        consumerGate: AudioOwnershipGate? = nil
    ) throws {
        guard sampleRate > 0, sampleRate <= 768_000 else {
            throw AudioRingConfigurationError.invalidSampleRate
        }
        guard channelCount == 1 || channelCount == 2 else {
            throw AudioRingConfigurationError.invalidChannelCount
        }
        guard capacitySeconds.isFinite, capacitySeconds >= 0.05, capacitySeconds <= 2.0 else {
            throw AudioRingConfigurationError.invalidCapacity
        }
        guard hostTicksPerSecond > 0, hostTicksPerSecond <= UInt64(Int64.max) else {
            throw AudioRingConfigurationError.invalidHostTimebase
        }
        let capacity = Int((Double(sampleRate) * capacitySeconds).rounded(.down))
        let frameSlot = max(1, sampleRate / 100)
        let slotsCount = capacity / frameSlot
        guard capacity > 0, slotsCount > 0, capacity <= Int.max / 4 else {
            throw AudioRingConfigurationError.invalidCapacity
        }
        self.role = role
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.hostTicksPerSecond = hostTicksPerSecond
        self.capacityFrames = capacity
        self.slotFrameCount = frameSlot
        self.slotCapacity = slotsCount
        writeSequence = AudioAtomicCounterFactory.make(mode: atomicMode)
        readSequence = AudioAtomicCounterFactory.make(mode: atomicMode)
        self.producerGate = producerGate ?? AudioOwnershipGate(mode: atomicMode)
        self.consumerGate = consumerGate ?? AudioOwnershipGate(mode: atomicMode)
        closedFlag = AudioAtomicCounterFactory.make(mode: atomicMode)
        finishedFlag = AudioAtomicCounterFactory.make(mode: atomicMode)
        unassignedGap = AudioAtomicCounterFactory.make(mode: atomicMode)
        acceptedCounter = AudioAtomicCounterFactory.make(mode: atomicMode)
        droppedCounter = AudioAtomicCounterFactory.make(mode: atomicMode)
        gapCounter = AudioAtomicCounterFactory.make(mode: atomicMode)
        reentrantCounter = AudioAtomicCounterFactory.make(mode: atomicMode)
        stagingCounter = AudioAtomicCounterFactory.make(mode: atomicMode)
        lastDropCode = AudioAtomicCounterFactory.make(mode: atomicMode)
        slotMetadata = UnsafeMutablePointer<AudioRingSlot>.allocate(capacity: slotsCount)
        slotMetadata.initialize(repeating: AudioRingSlot(), count: slotsCount)
        let sampleCount = slotsCount * channelCount * frameSlot
        slotSamples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
        slotSamples.initialize(repeating: 0, count: sampleCount)
        stagingChannels = (0..<channelCount).map { _ in
            [Float](repeating: 0, count: frameSlot)
        }
    }
    deinit {
        slotMetadata.deinitialize(count: slotCapacity)
        slotMetadata.deallocate()
        slotSamples.deinitialize(count: slotCapacity * channelCount * slotFrameCount)
        slotSamples.deallocate()
    }
    /// Whether the ring is closed, drained, and has no retained staging.
    public var isClosedAndEmpty: Bool {
        closedFlag.loadAcquire() != 0
            && stagingCounter.loadAcquire() == 0
            && writeSequence.loadAcquire() == readSequence.loadAcquire()
            && producerGate.isHeld == false
            && unassignedGap.loadAcquire() == 0
    }
    /// A non-instantaneous snapshot of ring counters.
    public var stats: RingStats {
        RingStats(
            acceptedFrames: acceptedCounter.loadAcquire(),
            droppedFrames: droppedCounter.loadAcquire(),
            gapFrames: gapCounter.loadAcquire(),
            stagingFrames: Int(stagingCounter.loadAcquire()),
            producerMaxDepth: producerGate.maxObservedDepth,
            consumerMaxDepth: consumerGate.maxObservedDepth,
            reentrantRejects: Int(reentrantCounter.loadAcquire()),
            lastDropReason: Self.dropReason(for: lastDropCode.loadAcquire())
        )
    }
    /// Marks the ring closed without touching producer staging.
    public func requestClose() {
        closedFlag.fetchAddRelease(1)
    }
    /// Compatibility entry point; identical to ``requestClose()``.
    public func close() {
        requestClose()
    }
    /// Publishes the final short staging slot after the producer has stopped.
    /// If the slot table is full, staging is retained and the call can be
    /// retried after the consumer drains. This method never touches staging
    /// while a producer call is active.
    public func finishProducing() -> RingFinalizeResult {
        guard producerGate.tryAcquire() else {
            return RingFinalizeResult(
                flushedFrames: 0,
                retainedStagingFrames: Int(stagingCounter.loadAcquire()),
                producerStillActive: true
            )
        }
        defer { producerGate.release() }
        finishedFlag.fetchAddRelease(1)
        guard stagingCount > 0 else {
            return RingFinalizeResult(
                flushedFrames: 0,
                retainedStagingFrames: 0,
                producerStillActive: false
            )
        }
        let staged = stagingCount
        if publishStagingSlot() {
            return RingFinalizeResult(
                flushedFrames: staged,
                retainedStagingFrames: 0,
                producerStillActive: false
            )
        }
        return RingFinalizeResult(flushedFrames: 0, retainedStagingFrames: staged, producerStillActive: false)
    }
}
extension AudioSourceRingBuffer {
    /// Writes interleaved frames into the ring.
    public func write(
        interleaved: UnsafeBufferPointer<Float>,
        frameCount: Int,
        hostTime: UInt64
    ) -> RingWriteResult {
        guard producerGate.tryAcquire() else {
            return rejectReentrant(frameCount: frameCount)
        }
        defer { producerGate.release() }
        guard frameCount >= 0 else {
            return rejectInvalidFormat(frameCount: frameCount)
        }
        guard frameCount == 0 || interleaved.count / channelCount >= frameCount else {
            return rejectInvalidFormat(frameCount: frameCount)
        }
        return produceLocked(frameCount: frameCount, hostTime: hostTime) { frame, channel in
            interleaved[frame * channelCount + channel]
        }
    }
    /// Writes one buffer per channel into the ring.
    public func write(
        planar: [UnsafeBufferPointer<Float>],
        frameCount: Int,
        hostTime: UInt64
    ) -> RingWriteResult {
        guard producerGate.tryAcquire() else {
            return rejectReentrant(frameCount: frameCount)
        }
        defer { producerGate.release() }
        guard frameCount >= 0,
            planar.count == channelCount,
            planar.allSatisfy({ $0.count >= frameCount })
        else {
            return rejectInvalidFormat(frameCount: frameCount)
        }
        return produceLocked(frameCount: frameCount, hostTime: hostTime) { frame, channel in
            planar[channel][frame]
        }
    }
}
extension AudioSourceRingBuffer {
    /// Reads at most `maxFrames` owned frames.
    /// A partial read preserves the slot cursor; a gap stays attached to its
    /// following slot and is delivered once.
    /// - Parameter maxFrames: Maximum frames in the returned block.
    /// - Returns: An owned block plus gap and close state.
    public func read(maxFrames: Int) -> RingReadResult {
        guard maxFrames > 0 else {
            return RingReadResult(
                block: nil,
                gapFrames: 0,
                isClosedAndEmpty: false,
                reason: .invalidMaxFrames
            )
        }
        guard consumerGate.tryAcquire() else {
            reentrantCounter.fetchAddRelease(1)
            return RingReadResult(
                block: nil,
                gapFrames: 0,
                isClosedAndEmpty: false,
                reason: .reentrantConsumer
            )
        }
        defer { consumerGate.release() }
        return readLocked(maxFrames: maxFrames)
    }
}
extension AudioSourceRingBuffer {
    private func produceLocked(
        frameCount: Int,
        hostTime: UInt64,
        sample: (Int, Int) -> Float
    ) -> RingWriteResult {
        guard frameCount > 0 else {
            return RingWriteResult(acceptedFrames: 0, droppedFrames: 0, reason: nil)
        }
        guard closedFlag.loadAcquire() == 0, finishedFlag.loadAcquire() == 0 else {
            recordClosedDrop(frames: frameCount)
            return RingWriteResult(acceptedFrames: 0, droppedFrames: frameCount, reason: .closed)
        }
        guard timestamp(base: hostTime, frameOffset: frameCount - 1) != nil,
            nextSourceFrame <= Int64.max - Int64(frameCount)
        else {
            recordTimelineDrop(frames: frameCount, reason: .invalidTimestamp)
            advanceSourceFrameCount(frameCount)
            return RingWriteResult(acceptedFrames: 0, droppedFrames: frameCount, reason: .invalidTimestamp)
        }
        if stagingSealed && !publishStagingSlot() {
            recordTimelineDrop(frames: frameCount, reason: .overflow)
            advanceSourceFrameCount(frameCount)
            return RingWriteResult(acceptedFrames: 0, droppedFrames: frameCount, reason: .overflow)
        }
        var occupied = occupiedFrames()
        var accepted = 0
        var dropped = 0
        var frame = 0
        var resultReason: RingDropReason?
        while frame < frameCount {
            guard occupied < capacityFrames else {
                let remaining = frameCount - frame
                recordTimelineDrop(frames: remaining, reason: .overflow)
                if stagingCount > 0 {
                    stagingSealed = true
                }
                dropped += remaining
                nextSourceFrame += Int64(remaining)
                resultReason = .overflow
                break
            }
            if stagingCount == 0 {
                beginStaging(hostTime: hostTime, frameOffset: frame)
            }
            let available = min(slotFrameCount - stagingCount, frameCount - frame)
            let take = min(available, capacityFrames - occupied)
            copyIntoStaging(sample: sample, frameOffset: frame, count: take)
            stagingCount += take
            stagingCounter.fetchAddRelease(Int64(take))
            occupied += take
            accepted += take
            frame += take
            nextSourceFrame += Int64(take)
            if stagingCount == slotFrameCount && !publishStagingSlot() {
                stagingSealed = true
                let remaining = frameCount - frame
                if remaining > 0 {
                    recordTimelineDrop(frames: remaining, reason: .overflow)
                    dropped += remaining
                    nextSourceFrame += Int64(remaining)
                    resultReason = .overflow
                }
                break
            }
        }
        acceptedCounter.fetchAddRelease(Int64(accepted))
        return RingWriteResult(
            acceptedFrames: accepted,
            droppedFrames: dropped,
            reason: resultReason
        )
    }
    private func beginStaging(hostTime: UInt64, frameOffset: Int) {
        let slotHost = timestamp(base: hostTime, frameOffset: frameOffset) ?? hostTime
        stagingHostTime = slotHost
        stagingRangeStart = nextSourceFrame
        stagingGapBefore = gapCarry
        if gapCarry > 0 {
            unassignedGap.fetchAddRelease(-Int64(gapCarry))
            gapCarry = 0
        }
    }
    private func copyIntoStaging(
        sample: (Int, Int) -> Float,
        frameOffset: Int,
        count: Int
    ) {
        for channel in 0..<channelCount {
            for offset in 0..<count {
                stagingChannels[channel][stagingCount + offset] = sample(frameOffset + offset, channel)
            }
        }
    }
    @discardableResult
    private func publishStagingSlot() -> Bool {
        let usedSlots = publishedSlotCount - readSequence.loadAcquire()
        guard stagingCount > 0, usedSlots < Int64(slotCapacity) else {
            return false
        }
        let slotIndex = nextWriteSlot
        let frames = stagingCount
        slotMetadata[slotIndex] = AudioRingSlot(
            frameCount: frames,
            hostTime: stagingHostTime,
            rangeStart: stagingRangeStart,
            gapBefore: stagingGapBefore
        )
        for channel in 0..<channelCount {
            let base = sampleIndex(slot: slotIndex, channel: channel)
            for offset in 0..<frames {
                slotSamples[base + offset] = stagingChannels[channel][offset]
            }
        }
        publishedSlotCount += 1
        writeSequence.fetchAddRelease(1)
        nextWriteSlot = (nextWriteSlot + 1) % slotCapacity
        stagingCount = 0
        stagingCounter.fetchAddRelease(-Int64(frames))
        stagingGapBefore = 0
        stagingSealed = false
        return true
    }
}
extension AudioSourceRingBuffer {
    private func readLocked(maxFrames: Int) -> RingReadResult {
        var output = [[Float]](repeating: [], count: channelCount)
        let reserve = min(maxFrames, maximumAvailableFrames())
        for channel in 0..<channelCount {
            output[channel].reserveCapacity(reserve)
        }
        var collected = 0
        var blockStart: Int64 = 0
        var blockHostTime: UInt64 = 0
        var deliveredGap = 0
        var hasBlock = false
        while collected < maxFrames {
            if partialSlotRemaining == 0 {
                let prepared = prepareNextSlot(
                    hasBlock: hasBlock,
                    blockStart: blockStart,
                    collected: collected
                )
                if !prepared {
                    break
                }
            }
            let slot = slotMetadata[partialSlotIndex]
            let take = min(partialSlotRemaining, maxFrames - collected)
            if !hasBlock {
                blockStart = slot.rangeStart + Int64(partialSlotOffset)
                let slotTimestamp = timestamp(
                    base: slot.hostTime,
                    frameOffset: partialSlotOffset
                )
                blockHostTime = slotTimestamp ?? slot.hostTime
                deliveredGap = pendingSlotGap
                pendingSlotGap = 0
                hasBlock = true
            }
            for channel in 0..<channelCount {
                let start = sampleIndex(slot: partialSlotIndex, channel: channel) + partialSlotOffset
                output[channel].append(
                    contentsOf: UnsafeBufferPointer(
                        start: slotSamples.advanced(by: start),
                        count: take
                    )
                )
            }
            collected += take
            partialSlotOffset += take
            partialSlotRemaining -= take
            if partialSlotRemaining == 0 {
                releaseCurrentSlot()
            }
        }
        guard hasBlock else {
            return emptyReadResult()
        }
        let isSilence = output.allSatisfy { $0.allSatisfy { $0 == 0 } }
        let block = AudioPCMBlock(
            role: role,
            range: SampleRange(startSample: blockStart, sampleCount: Int64(collected)),
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: collected,
            hostTime: blockHostTime,
            channels: output,
            isSilence: isSilence
        )
        return RingReadResult(
            block: block,
            gapFrames: deliveredGap,
            isClosedAndEmpty: false,
            reason: nil
        )
    }
    private func prepareNextSlot(hasBlock: Bool, blockStart: Int64, collected: Int) -> Bool {
        let write = writeSequence.loadAcquire()
        guard nextReadSequence < write else {
            return false
        }
        let index = nextReadSlot
        let slot = slotMetadata[index]
        guard slot.frameCount > 0 else {
            return false
        }
        if hasBlock {
            guard slot.gapBefore == 0 else { return false }
            guard slot.rangeStart == blockStart + Int64(collected) else { return false }
        }
        partialSlotIndex = index
        partialSlotOffset = 0
        partialSlotRemaining = slot.frameCount
        pendingSlotGap = slot.gapBefore
        return true
    }
    private func releaseCurrentSlot() {
        nextReadSequence += 1
        readSequence.fetchAddRelease(1)
        nextReadSlot = (nextReadSlot + 1) % slotCapacity
        partialSlotOffset = 0
        pendingSlotGap = 0
    }
    private func emptyReadResult() -> RingReadResult {
        let closed = closedFlag.loadAcquire() != 0
        if closed, stagingCounter.loadAcquire() == 0, !producerGate.isHeld {
            let pendingGap = unassignedGap.loadAcquire()
            let gap = Int(pendingGap)
            if gap > 0 && !terminalGapDelivered {
                terminalGapDelivered = true
                unassignedGap.fetchAddAcqRel(-pendingGap)
                return RingReadResult(
                    block: nil,
                    gapFrames: gap,
                    isClosedAndEmpty: true,
                    reason: nil
                )
            }
        }
        return RingReadResult(
            block: nil,
            gapFrames: 0,
            isClosedAndEmpty: isClosedAndEmpty,
            reason: nil
        )
    }
    private func maximumAvailableFrames() -> Int {
        let write = writeSequence.loadAcquire()
        let queuedSlots = max(0, Int(write - nextReadSequence))
        return partialSlotRemaining + queuedSlots * slotFrameCount
    }
    private func timestamp(base: UInt64, frameOffset: Int) -> UInt64? {
        guard frameOffset >= 0 else {
            return nil
        }
        let (scaled, multiplyOverflow) = UInt64(frameOffset).multipliedReportingOverflow(
            by: hostTicksPerSecond
        )
        guard !multiplyOverflow else {
            return nil
        }
        let (delta, addOverflow) = base.addingReportingOverflow(scaled / UInt64(sampleRate))
        guard !addOverflow else {
            return nil
        }
        return delta
    }
    private func sampleIndex(slot: Int, channel: Int) -> Int {
        (slot * channelCount + channel) * slotFrameCount
    }
    private func occupiedFrames() -> Int {
        let queuedSlots = max(0, publishedSlotCount - readSequence.loadAcquire())
        return Int(queuedSlots * Int64(slotFrameCount)) + stagingCount
    }
    private func rejectReentrant(frameCount: Int) -> RingWriteResult {
        reentrantCounter.fetchAddRelease(1)
        let dropped = max(0, frameCount)
        if dropped > 0 {
            droppedCounter.fetchAddRelease(Int64(dropped))
        }
        return RingWriteResult(
            acceptedFrames: 0,
            droppedFrames: dropped,
            reason: .reentrantProducer
        )
    }
    private func rejectInvalidFormat(frameCount: Int) -> RingWriteResult {
        let dropped = max(0, frameCount)
        recordTimelineDrop(frames: dropped, reason: .invalidFormat)
        advanceSourceFrameCount(dropped)
        if stagingCount > 0 {
            stagingSealed = true
        }
        return RingWriteResult(acceptedFrames: 0, droppedFrames: dropped, reason: .invalidFormat)
    }
    private func advanceSourceFrameCount(_ frames: Int) {
        guard frames > 0 else {
            return
        }
        let (next, overflow) = nextSourceFrame.addingReportingOverflow(Int64(frames))
        if !overflow {
            nextSourceFrame = next
        }
    }
    private func recordClosedDrop(frames: Int) {
        droppedCounter.fetchAddRelease(Int64(frames))
        setLastDropReason(.closed)
    }
    private func recordTimelineDrop(frames: Int, reason: RingDropReason) {
        guard frames > 0 else {
            return
        }
        droppedCounter.fetchAddRelease(Int64(frames))
        gapCounter.fetchAddRelease(Int64(frames))
        gapCarry += frames
        unassignedGap.fetchAddRelease(Int64(frames))
        setLastDropReason(reason)
    }
    private func setLastDropReason(_ reason: RingDropReason) {
        let code = Self.code(for: reason)
        let current = lastDropCode.loadAcquire()
        if current != code {
            lastDropCode.fetchAddRelease(code - current)
        }
    }
    private static func code(for reason: RingDropReason) -> Int64 {
        switch reason {
        case .overflow: 1
        case .closed: 2
        case .reentrantProducer: 3
        case .reentrantConsumer: 4
        case .invalidFormat: 5
        case .invalidTimestamp: 6
        }
    }
    private static func dropReason(for code: Int64) -> RingDropReason? {
        switch code {
        case 1: .overflow
        case 2: .closed
        case 3: .reentrantProducer
        case 4: .reentrantConsumer
        case 5: .invalidFormat
        case 6: .invalidTimestamp
        default: nil
        }
    }
}
