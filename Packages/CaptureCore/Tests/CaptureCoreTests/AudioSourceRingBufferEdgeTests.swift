import Dispatch
import Foundation
import Testing

@testable import CaptureCore

struct AudioSourceRingBufferEdgeTests {
    private final class EdgeState: @unchecked Sendable {
        private let lock = NSLock()
        private var storedFailure: String?
        private var storedStatsReads = 0

        var failure: String? {
            lock.lock()
            defer { lock.unlock() }
            return storedFailure
        }

        var statsReads: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedStatsReads
        }

        func record(_ message: String) {
            lock.lock()
            if storedFailure == nil {
                storedFailure = message
            }
            lock.unlock()
        }

        func countStatsRead() {
            lock.lock()
            storedStatsReads += 1
            lock.unlock()
        }
    }

    private final class AtomicFlag: @unchecked Sendable {
        let counter: any AudioAtomicCounter

        init() {
            counter = AudioAtomicCounterFactory.make(mode: .automatic)
        }
    }

    @Test func ringLevelReentrantProducerIsDeterministic() throws {
        for _ in 0..<20 {
            let gate = AudioOwnershipGate(mode: .automatic)
            let ring = try AudioSourceRingBuffer(
                role: .system,
                sampleRate: 48_000,
                channelCount: 2,
                hostTicksPerSecond: 1_000_000_000,
                capacitySeconds: 0.05,
                atomicMode: .automatic,
                producerGate: gate
            )
            #expect(gate.tryAcquire())
            let chunk = RingTestSupport.interleavedChunk(
                frameCount: 480,
                channelCount: 2,
                firstFrame: 0
            )
            let rejected = RingTestSupport.write(
                ring,
                interleaved: chunk,
                frameCount: 480,
                channelCount: 2
            )
            #expect(rejected.acceptedFrames == 0)
            #expect(rejected.droppedFrames == 480)
            #expect(rejected.reason == .reentrantProducer)
            #expect(ring.stats.droppedFrames == 480)
            #expect(ring.stats.gapFrames == 0)
            #expect(ring.stats.lastDropReason == nil)
            #expect(ring.stats.reentrantRejects == 1)
            #expect(ring.stats.stagingFrames == 0)
            gate.release()

            let accepted = RingTestSupport.write(
                ring,
                interleaved: chunk,
                frameCount: 480,
                channelCount: 2
            )
            #expect(accepted.acceptedFrames == 480)
            let block = ring.read(maxFrames: 480)
            #expect(block.block?.range.startSample == 0)
            #expect(block.block?.channels[0][0] == 0)
            #expect(block.block?.channels[1][0] == 0)
            #expect(ring.stats.gapFrames == 0)
        }
    }

    @Test func ringLevelReentrantConsumerIsDeterministic() throws {
        for _ in 0..<20 {
            let gate = AudioOwnershipGate(mode: .automatic)
            let ring = try AudioSourceRingBuffer(
                role: .system,
                sampleRate: 48_000,
                channelCount: 2,
                hostTicksPerSecond: 1_000_000_000,
                capacitySeconds: 0.05,
                atomicMode: .automatic,
                consumerGate: gate
            )
            let chunk = RingTestSupport.interleavedChunk(
                frameCount: 480,
                channelCount: 2,
                firstFrame: 0
            )
            #expect(
                RingTestSupport.write(
                    ring,
                    interleaved: chunk,
                    frameCount: 480,
                    channelCount: 2
                ).acceptedFrames == 480
            )
            _ = ring.finishProducing()
            #expect(gate.tryAcquire())

            let rejected = ring.read(maxFrames: 480)
            #expect(rejected.block == nil)
            #expect(rejected.gapFrames == 0)
            #expect(rejected.reason == .reentrantConsumer)
            #expect(ring.stats.reentrantRejects == 1)
            #expect(ring.stats.consumerMaxDepth == 1)
            gate.release()

            let block = ring.read(maxFrames: 480)
            #expect(block.block?.frameCount == 480)
            #expect(block.block?.range.startSample == 0)
            #expect(block.block?.channels[0][0] == 0)
            #expect(block.block?.channels[1][0] == 0)
        }
    }

    @Test(arguments: [AudioAtomicBackendMode.automatic, AudioAtomicBackendMode.legacyForTesting])
    func concurrentReentrantProducersDoNotOverwriteLastDropReason(
        mode: AudioAtomicBackendMode
    ) throws {
        for _ in 0..<20 {
            try assertReentrantProducerLosers(mode: mode)
        }
        try assertPreviousGateDropIsPreserved(mode: mode)
    }

    @Test func propertyStaysNotEmptyUntilTerminalGapIsDelivered() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let full = RingTestSupport.interleavedChunk(
            frameCount: 2_400,
            channelCount: 2,
            firstFrame: 0
        )
        _ = RingTestSupport.write(ring, interleaved: full, frameCount: 2_400, channelCount: 2)
        let overflow = RingTestSupport.interleavedChunk(
            frameCount: 123,
            channelCount: 2,
            firstFrame: 2_400
        )
        let rejected = RingTestSupport.write(
            ring,
            interleaved: overflow,
            frameCount: 123,
            channelCount: 2
        )
        #expect(rejected.droppedFrames == 123)
        #expect(rejected.reason == .overflow)
        _ = ring.finishProducing()
        ring.requestClose()

        var blocks = 0
        for _ in 0..<5 {
            let result = ring.read(maxFrames: 480)
            #expect(result.block?.frameCount == 480)
            blocks += result.block?.frameCount ?? 0
        }
        #expect(blocks == 2_400)
        #expect(ring.isClosedAndEmpty == false)

        let terminal = ring.read(maxFrames: 480)
        #expect(terminal.block == nil)
        #expect(terminal.gapFrames == 123)
        #expect(terminal.isClosedAndEmpty)
        #expect(ring.isClosedAndEmpty)

        let repeated = ring.read(maxFrames: 480)
        #expect(repeated.block == nil)
        #expect(repeated.gapFrames == 0)
        #expect(repeated.isClosedAndEmpty)
        #expect(ring.isClosedAndEmpty)
    }

    @Test(arguments: [(48_000, 96_000, 480), (44_100, 88_200, 441)])
    func productionTwoSecondCapacityUsesExactFrames(
        sampleRate: Int,
        capacityFrames: Int,
        slotFrameCount: Int
    ) throws {
        let ring = try RingTestSupport.makeRing(
            sampleRate: sampleRate,
            channelCount: 2,
            capacitySeconds: 2.0
        )
        #expect(ring.capacityFrames == capacityFrames)
        #expect(ring.slotFrameCount == slotFrameCount)

        let samples = [Float](repeating: 0.25, count: capacityFrames * 2)
        let accepted = RingTestSupport.write(
            ring,
            interleaved: samples,
            frameCount: capacityFrames,
            channelCount: 2
        )
        #expect(accepted.acceptedFrames == capacityFrames)
        #expect(accepted.droppedFrames == 0)
        #expect(accepted.reason == nil)

        let oneFrame = [Float](repeating: 0.5, count: 2)
        let boundary = RingTestSupport.write(
            ring,
            interleaved: oneFrame,
            frameCount: 1,
            channelCount: 2
        )
        #expect(boundary.acceptedFrames == 0)
        #expect(boundary.droppedFrames == 1)
        #expect(boundary.reason == .overflow)
        #expect(ring.finishProducing().retainedStagingFrames == 0)
        ring.requestClose()

        let result = RingTestSupport.drain(ring, maxFrames: 8_192)
        #expect(result.closed)
        #expect(result.blocks.reduce(0) { $0 + $1.frameCount } == capacityFrames)
        #expect(ring.stats.acceptedFrames == Int64(capacityFrames))
        #expect(ring.stats.droppedFrames == 1)
    }

    @Test func concurrentStatsSnapshotsAreMonotonicAndBounded() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let flag = AtomicFlag()
        let state = EdgeState()
        let statsReady = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "audio.edge.stats", attributes: .concurrent)

        group.enter()
        queue.async {
            let result = ring.read(maxFrames: 480)
            #expect(result.block == nil)
            statsReady.signal()
            var lastAccepted: Int64 = 0
            var lastDropped: Int64 = 0
            var lastGap: Int64 = 0
            while flag.counter.loadAcquire() == 0 {
                let stats = ring.stats
                let countersWentBackwards =
                    stats.acceptedFrames < lastAccepted
                    || stats.droppedFrames < lastDropped
                    || stats.gapFrames < lastGap
                if countersWentBackwards {
                    state.record("a monotonic stats counter went backwards")
                    break
                }
                if stats.stagingFrames < 0 || stats.stagingFrames > ring.slotFrameCount {
                    state.record("stagingFrames outside slot range")
                    break
                }
                if stats.producerMaxDepth > 1 || stats.consumerMaxDepth > 1 {
                    state.record("ownership depth exceeded one")
                    break
                }
                if stats.reentrantRejects < 0 {
                    state.record("reentrantRejects became negative")
                    break
                }
                lastAccepted = stats.acceptedFrames
                lastDropped = stats.droppedFrames
                lastGap = stats.gapFrames
                state.countStatsRead()
            }
            group.leave()
        }

        statsReady.wait()
        group.enter()
        queue.async {
            let chunk = RingTestSupport.interleavedChunk(
                frameCount: 480,
                channelCount: 2,
                firstFrame: 0
            )
            for _ in 0..<20_000 {
                _ = RingTestSupport.write(
                    ring,
                    interleaved: chunk,
                    frameCount: 480,
                    channelCount: 2
                )
            }
            flag.counter.fetchAddRelease(1)
            group.leave()
        }
        group.wait()

        #expect(state.failure == nil)
        #expect(state.statsReads > 0)
        #expect(ring.stats.acceptedFrames <= 2_400)
        #expect(ring.stats.droppedFrames > 0)
        ring.requestClose()
    }
}

private final class ReentrantWriteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RingWriteResult] = []

    var results: [RingWriteResult] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ result: RingWriteResult) {
        lock.lock()
        stored.append(result)
        lock.unlock()
    }
}

private func makeReentrantTestRing(
    mode: AudioAtomicBackendMode,
    gate: AudioOwnershipGate
) throws -> AudioSourceRingBuffer {
    try AudioSourceRingBuffer(
        role: .system,
        sampleRate: 48_000,
        channelCount: 2,
        hostTicksPerSecond: 1_000_000_000,
        capacitySeconds: 0.05,
        atomicMode: mode,
        producerGate: gate
    )
}

private func launchTwoReentrantWrites(
    ring: AudioSourceRingBuffer,
    chunk: [Float]
) -> [RingWriteResult] {
    let collector = ReentrantWriteCollector()
    let group = DispatchGroup()
    let queue = DispatchQueue(
        label: "audio.edge.reentrant",
        attributes: .concurrent
    )
    for _ in 0..<2 {
        group.enter()
        queue.async {
            collector.append(
                RingTestSupport.write(
                    ring,
                    interleaved: chunk,
                    frameCount: 480,
                    channelCount: 2
                )
            )
            group.leave()
        }
    }
    group.wait()
    return collector.results
}

private func assertReentrantProducerLosers(mode: AudioAtomicBackendMode) throws {
    let gate = AudioOwnershipGate(mode: mode)
    let ring = try makeReentrantTestRing(mode: mode, gate: gate)
    #expect(gate.tryAcquire())
    let chunk = RingTestSupport.interleavedChunk(
        frameCount: 480,
        channelCount: 2,
        firstFrame: 0
    )
    let results = launchTwoReentrantWrites(ring: ring, chunk: chunk)
    #expect(results.count == 2)
    #expect(results.allSatisfy { $0.acceptedFrames == 0 })
    #expect(results.allSatisfy { $0.droppedFrames == 480 })
    #expect(results.allSatisfy { $0.reason == .reentrantProducer })
    #expect(ring.stats.acceptedFrames == 0)
    #expect(ring.stats.droppedFrames == 960)
    #expect(ring.stats.gapFrames == 0)
    #expect(ring.stats.reentrantRejects == 2)
    #expect(ring.stats.lastDropReason == nil)
    gate.release()

    let accepted = RingTestSupport.write(
        ring,
        interleaved: chunk,
        frameCount: 480,
        channelCount: 2
    )
    #expect(accepted.acceptedFrames == 480)
    #expect(accepted.droppedFrames == 0)
    let block = ring.read(maxFrames: 480)
    #expect(block.block?.range.startSample == 0)
    #expect(block.block?.channels[0][0] == 0)
    #expect(block.block?.channels[1][0] == 0)
}

private func assertPreviousGateDropIsPreserved(mode: AudioAtomicBackendMode) throws {
    let gate = AudioOwnershipGate(mode: mode)
    let ring = try makeReentrantTestRing(mode: mode, gate: gate)
    ring.requestClose()
    let chunk = RingTestSupport.interleavedChunk(
        frameCount: 480,
        channelCount: 2,
        firstFrame: 0
    )
    let closedDrop = RingTestSupport.write(
        ring,
        interleaved: chunk,
        frameCount: 480,
        channelCount: 2
    )
    #expect(closedDrop.reason == .closed)
    #expect(ring.stats.lastDropReason == .closed)
    #expect(gate.tryAcquire())
    let results = launchTwoReentrantWrites(ring: ring, chunk: chunk)
    #expect(results.allSatisfy { $0.reason == .reentrantProducer })
    #expect(ring.stats.lastDropReason == .closed)
    #expect(ring.stats.gapFrames == 0)
    #expect(ring.stats.droppedFrames == 1_440)
    #expect(ring.stats.reentrantRejects == 2)
    gate.release()
}
