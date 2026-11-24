import Foundation
import Testing

@testable import CaptureCore

struct RingDrainOutcome {
    let blocks: [AudioPCMBlock]
    let totalGap: Int
    let closed: Bool
}
struct RingTestSupport {
    struct RingFormatCase: Sendable, CustomTestStringConvertible {
        let sampleRate: Int
        let channelCount: Int
        let mode: AudioAtomicBackendMode
        var testDescription: String {
            "rate=\(sampleRate) channels=\(channelCount) mode=\(mode)"
        }
    }
    static let formatCases = [
        RingFormatCase(sampleRate: 44_100, channelCount: 1, mode: .automatic),
        RingFormatCase(sampleRate: 44_100, channelCount: 2, mode: .legacyForTesting),
        RingFormatCase(sampleRate: 48_000, channelCount: 1, mode: .legacyForTesting),
        RingFormatCase(sampleRate: 48_000, channelCount: 2, mode: .automatic),
    ]
    static func makeRing(
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        capacitySeconds: Double = 0.05,
        hostTicksPerSecond: UInt64 = 1_000_000_000,
        mode: AudioAtomicBackendMode = .automatic
    ) throws -> AudioSourceRingBuffer {
        try AudioSourceRingBuffer(
            role: .system,
            sampleRate: sampleRate,
            channelCount: channelCount,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: capacitySeconds,
            atomicMode: mode
        )
    }
    static func interleavedChunk(
        frameCount: Int,
        channelCount: Int,
        firstFrame: Int
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            let value = Float((firstFrame + frame) % 997)
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = value
            }
        }
        return samples
    }
    static func planarChunk(
        frameCount: Int,
        channelCount: Int,
        firstFrame: Int
    ) -> [[Float]] {
        (0..<channelCount).map { channel in
            (0..<frameCount).map { frame in
                Float(((firstFrame + frame) % 997) * (channel + 1))
            }
        }
    }
    static func write(
        _ ring: AudioSourceRingBuffer,
        interleaved samples: [Float],
        frameCount: Int,
        channelCount: Int,
        hostTime: UInt64 = 1_000
    ) -> RingWriteResult {
        samples.withUnsafeBufferPointer { buffer in
            ring.write(interleaved: buffer, frameCount: frameCount, hostTime: hostTime)
        }
    }
    static func write(
        _ ring: AudioSourceRingBuffer,
        planar channels: [[Float]],
        frameCount: Int,
        hostTime: UInt64 = 1_000
    ) -> RingWriteResult {
        func writeChannels(_ index: Int, _ pointers: [UnsafeBufferPointer<Float>]) -> RingWriteResult {
            guard index < channels.count else {
                return ring.write(planar: pointers, frameCount: frameCount, hostTime: hostTime)
            }
            return channels[index].withUnsafeBufferPointer {
                writeChannels(index + 1, pointers + [$0])
            }
        }
        return writeChannels(0, [])
    }
    static func drain(
        _ ring: AudioSourceRingBuffer,
        maxFrames: Int = 4_096
    ) -> RingDrainOutcome {
        var blocks: [AudioPCMBlock] = []
        var totalGap = 0
        for _ in 0..<10_000 {
            let result = ring.read(maxFrames: maxFrames)
            if let block = result.block {
                blocks.append(block)
            }
            totalGap += result.gapFrames
            if result.isClosedAndEmpty && result.block == nil {
                return RingDrainOutcome(blocks: blocks, totalGap: totalGap, closed: true)
            }
            if result.block == nil && result.reason != nil {
                return RingDrainOutcome(blocks: blocks, totalGap: totalGap, closed: false)
            }
        }
        return RingDrainOutcome(blocks: blocks, totalGap: totalGap, closed: false)
    }
}
struct AudioSourceRingBufferTests {
    @Test(arguments: RingTestSupport.formatCases)
    func sequentialWritesRoundTripWithoutLoss(format: RingTestSupport.RingFormatCase) throws {
        let ring = try RingTestSupport.makeRing(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            mode: format.mode
        )
        let chunk = RingTestSupport.interleavedChunk(
            frameCount: 1_024,
            channelCount: format.channelCount,
            firstFrame: 0
        )
        let write = RingTestSupport.write(
            ring,
            interleaved: chunk,
            frameCount: 1_024,
            channelCount: format.channelCount
        )
        #expect(write.acceptedFrames == 1_024)
        #expect(write.droppedFrames == 0)
        #expect(write.reason == nil)
        let finalize = ring.finishProducing()
        #expect(finalize.retainedStagingFrames == 0)
        #expect(finalize.flushedFrames == 1_024 % ring.slotFrameCount)
        ring.requestClose()
        let result = RingTestSupport.drain(ring, maxFrames: 128)
        #expect(result.closed)
        #expect(result.totalGap == 0)
        #expect(result.blocks.reduce(0) { $0 + $1.frameCount } == 1_024)
        #expect(result.blocks.first?.range.startSample == 0)
        #expect(result.blocks.allSatisfy { $0.sampleRate == format.sampleRate })
        #expect(result.blocks.allSatisfy { $0.channelCount == format.channelCount })
        #expect(result.blocks.allSatisfy { $0.role == .system })
        var expectedFrame = 0
        for block in result.blocks {
            #expect(block.range.startSample == Int64(expectedFrame))
            for channel in block.channels {
                #expect(channel.count == block.frameCount)
                for index in 0..<block.frameCount {
                    #expect(channel[index] == Float((expectedFrame + index) % 997))
                }
            }
            expectedFrame += block.frameCount
        }
    }
    @Test(arguments: [1, 479, 481])
    func tailFrameCountsArePublishedAtFinish(frameCount: Int) throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let samples = RingTestSupport.interleavedChunk(frameCount: frameCount, channelCount: 2, firstFrame: 0)
        let write = RingTestSupport.write(ring, interleaved: samples, frameCount: frameCount, channelCount: 2)
        #expect(write.acceptedFrames == frameCount)
        #expect(write.droppedFrames == 0)
        let finalize = ring.finishProducing()
        #expect(finalize.producerStillActive == false)
        #expect(finalize.retainedStagingFrames == 0)
        ring.requestClose()
        let result = RingTestSupport.drain(ring, maxFrames: ring.slotFrameCount)
        #expect(result.closed)
        #expect(result.totalGap == 0)
        #expect(result.blocks.reduce(0) { $0 + $1.frameCount } == frameCount)
        #expect(
            result.blocks.last?.frameCount
                == (frameCount % ring.slotFrameCount == 0
                    ? ring.slotFrameCount
                    : frameCount % ring.slotFrameCount))
    }
    @Test func fullSlotTableRetainsTailUntilConsumerDrains() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.0501)
        #expect(ring.capacityFrames == 2_404)
        #expect(ring.slotFrameCount == 480)
        let samples = RingTestSupport.interleavedChunk(frameCount: 2_404, channelCount: 2, firstFrame: 0)
        let write = RingTestSupport.write(ring, interleaved: samples, frameCount: 2_404, channelCount: 2)
        #expect(write.acceptedFrames == 2_404)
        #expect(write.droppedFrames == 0)
        #expect(ring.stats.stagingFrames == 4)
        #expect(ring.stats.acceptedFrames + ring.stats.droppedFrames == 2_404)
        let firstFinalize = ring.finishProducing()
        #expect(firstFinalize.producerStillActive == false)
        #expect(firstFinalize.flushedFrames == 0)
        #expect(firstFinalize.retainedStagingFrames == 4)
        ring.requestClose()
        var blocks: [AudioPCMBlock] = []
        for _ in 0..<5 {
            let result = ring.read(maxFrames: 480)
            if let block = result.block {
                blocks.append(block)
            }
        }
        #expect(blocks.reduce(0) { $0 + $1.frameCount } == 2_400)
        let secondFinalize = ring.finishProducing()
        #expect(secondFinalize.retainedStagingFrames == 0)
        #expect(secondFinalize.flushedFrames == 4)
        let tail = ring.read(maxFrames: 480)
        #expect(tail.block?.frameCount == 4)
        #expect(tail.gapFrames == 0)
        let terminal = ring.read(maxFrames: 480)
        #expect(terminal.block == nil)
        #expect(terminal.isClosedAndEmpty)
        #expect(terminal.gapFrames == 0)
        #expect(ring.isClosedAndEmpty)
    }
    @Test func overflowGapAttachesToNextPublishedSlot() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let full = RingTestSupport.interleavedChunk(frameCount: 2_400, channelCount: 2, firstFrame: 0)
        _ = RingTestSupport.write(ring, interleaved: full, frameCount: 2_400, channelCount: 2)
        let overflow = RingTestSupport.interleavedChunk(frameCount: 480, channelCount: 2, firstFrame: 2_400)
        let rejected = RingTestSupport.write(ring, interleaved: overflow, frameCount: 480, channelCount: 2)
        #expect(rejected.acceptedFrames == 0)
        #expect(rejected.droppedFrames == 480)
        #expect(rejected.reason == .overflow)
        #expect(ring.stats.gapFrames == 480)
        for index in 0..<5 {
            let result = ring.read(maxFrames: 480)
            #expect(result.block?.range.startSample == Int64(index * 480))
            #expect(result.gapFrames == 0)
        }
        let next = RingTestSupport.interleavedChunk(frameCount: 480, channelCount: 2, firstFrame: 2_880)
        let accepted = RingTestSupport.write(ring, interleaved: next, frameCount: 480, channelCount: 2)
        #expect(accepted.acceptedFrames == 480)
        let gapCarrier = ring.read(maxFrames: 480)
        #expect(gapCarrier.gapFrames == 480)
        #expect(gapCarrier.block?.range.startSample == 2_880)
        ring.requestClose()
        let terminal = ring.read(maxFrames: 480)
        #expect(terminal.block == nil)
        #expect(terminal.isClosedAndEmpty)
        #expect(terminal.gapFrames == 0)
    }
    @Test func terminalGapIsDeliveredExactlyOnce() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let full = RingTestSupport.interleavedChunk(frameCount: 2_400, channelCount: 2, firstFrame: 0)
        _ = RingTestSupport.write(ring, interleaved: full, frameCount: 2_400, channelCount: 2)
        let overflow = RingTestSupport.interleavedChunk(frameCount: 123, channelCount: 2, firstFrame: 2_400)
        _ = RingTestSupport.write(ring, interleaved: overflow, frameCount: 123, channelCount: 2)
        _ = ring.finishProducing()
        ring.requestClose()
        let result = RingTestSupport.drain(ring)
        #expect(result.closed)
        #expect(result.totalGap == 123)
        #expect(result.blocks.reduce(0) { $0 + $1.frameCount } == 2_400)
        let repeated = ring.read(maxFrames: 480)
        #expect(repeated.block == nil)
        #expect(repeated.gapFrames == 0)
        #expect(repeated.isClosedAndEmpty)
    }
    @Test func partialReadsPreserveSlotCursorAndRanges() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let samples = RingTestSupport.interleavedChunk(frameCount: 1_024, channelCount: 2, firstFrame: 0)
        _ = RingTestSupport.write(ring, interleaved: samples, frameCount: 1_024, channelCount: 2)
        _ = ring.finishProducing()
        ring.requestClose()
        var framesRead = 0
        var expectedStart = 0
        for _ in 0..<6 {
            let result = ring.read(maxFrames: 100)
            guard let block = result.block else {
                Issue.record("expected a block at frame \(framesRead)")
                return
            }
            #expect(block.frameCount == 100)
            #expect(block.range.startSample == Int64(expectedStart))
            framesRead += block.frameCount
            expectedStart += block.frameCount
        }
        #expect(framesRead == 600)
        let remainder = ring.read(maxFrames: 1_000)
        #expect(remainder.block?.frameCount == 424)
        #expect(remainder.block?.range.startSample == 600)
    }
    @Test func invalidMaxFramesIsReportedWithoutConsuming() throws {
        let ring = try RingTestSupport.makeRing()
        #expect(ring.read(maxFrames: 0).reason == .invalidMaxFrames)
        #expect(ring.read(maxFrames: -4).reason == .invalidMaxFrames)
        #expect(ring.read(maxFrames: 0).block == nil)
        #expect(ring.stats.consumerMaxDepth == 0)
    }
    @Test func overflowNeverOverwritesUnreadSlots() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        var expected: [[Float]] = []
        for slot in 0..<5 {
            let chunk = RingTestSupport.interleavedChunk(
                frameCount: 480,
                channelCount: 2,
                firstFrame: slot * 480
            )
            expected.append(chunk)
            let result = RingTestSupport.write(ring, interleaved: chunk, frameCount: 480, channelCount: 2)
            #expect(result.acceptedFrames == 480)
        }
        for attempt in 0..<12 {
            let chunk = RingTestSupport.interleavedChunk(
                frameCount: 480,
                channelCount: 2,
                firstFrame: 10_000 + attempt * 480
            )
            let result = RingTestSupport.write(ring, interleaved: chunk, frameCount: 480, channelCount: 2)
            #expect(result.acceptedFrames == 0)
            #expect(result.reason == .overflow)
        }
        for slot in 0..<5 {
            let result = ring.read(maxFrames: 480)
            #expect(result.block?.range.startSample == Int64(slot * 480))
            let channel0 = stride(from: 0, to: 960, by: 2).map { expected[slot][$0] }
            let channel1 = stride(from: 1, to: 960, by: 2).map { expected[slot][$0] }
            #expect(result.block?.channels[0] == channel0)
            #expect(result.block?.channels[1] == channel1)
        }
    }
    @Test func planarWritesPreserveChannelsAndLargeChunks() throws {
        let ring = try RingTestSupport.makeRing(sampleRate: 48_000, channelCount: 2, capacitySeconds: 0.3)
        let channels = RingTestSupport.planarChunk(frameCount: 8_192, channelCount: 2, firstFrame: 0)
        let result = RingTestSupport.write(ring, planar: channels, frameCount: 8_192, hostTime: 5_000)
        #expect(result.acceptedFrames == 8_192)
        #expect(result.droppedFrames == 0)
        _ = ring.finishProducing()
        ring.requestClose()
        let drained = RingTestSupport.drain(ring)
        #expect(drained.closed)
        #expect(drained.blocks.reduce(0) { $0 + $1.frameCount } == 8_192)
        var offset = 0
        for block in drained.blocks {
            #expect(block.range.startSample == Int64(offset))
            #expect(block.channelCount == 2)
            #expect(block.channels[0][0] == Float(offset % 997))
            #expect(block.channels[1][0] == Float((offset % 997) * 2))
            offset += block.frameCount
        }
    }
    @Test func splitCallbacksUseCheckedTwentyFourMegahertzHostTime() throws {
        let ring = try RingTestSupport.makeRing(
            sampleRate: 48_000,
            channelCount: 2,
            capacitySeconds: 0.3,
            hostTicksPerSecond: 24_000_000
        )
        let samples = RingTestSupport.interleavedChunk(frameCount: 8_192, channelCount: 2, firstFrame: 0)
        _ = RingTestSupport.write(
            ring,
            interleaved: samples,
            frameCount: 8_192,
            channelCount: 2,
            hostTime: 1_000_000
        )
        _ = ring.finishProducing()
        ring.requestClose()
        let result = RingTestSupport.drain(ring)
        #expect(result.closed)
        for block in result.blocks {
            let offset = UInt64(block.range.startSample)
            #expect(block.hostTime == 1_000_000 + offset * 500)
        }
        #expect(result.blocks.first?.hostTime == 1_000_000)
    }
    @Test func fortyFourPointOneKilohertzUsesItsOwnFrameGrid() throws {
        let ring = try RingTestSupport.makeRing(sampleRate: 44_100, channelCount: 1, capacitySeconds: 0.2)
        #expect(ring.capacityFrames == 8_820)
        #expect(ring.slotFrameCount == 441)
        let samples = RingTestSupport.interleavedChunk(frameCount: 4_410, channelCount: 1, firstFrame: 0)
        _ = RingTestSupport.write(ring, interleaved: samples, frameCount: 4_410, channelCount: 1)
        _ = ring.finishProducing()
        ring.requestClose()
        let result = RingTestSupport.drain(ring, maxFrames: ring.slotFrameCount)
        #expect(result.blocks.reduce(0) { $0 + $1.frameCount } == 4_410)
        #expect(result.blocks.allSatisfy { $0.sampleRate == 44_100 })
        #expect(result.blocks.allSatisfy { $0.channelCount == 1 })
        #expect(result.blocks.last?.frameCount == 441)
    }
    @Test func invalidConfigurationThrowsWithoutTrapping() {
        #expect(throws: AudioRingConfigurationError.invalidSampleRate) {
            _ = try AudioSourceRingBuffer(
                role: .system,
                sampleRate: 0,
                channelCount: 2,
                hostTicksPerSecond: 1_000_000_000
            )
        }
        #expect(throws: AudioRingConfigurationError.invalidSampleRate) {
            _ = try AudioSourceRingBuffer(
                role: .system,
                sampleRate: -48_000,
                channelCount: 2,
                hostTicksPerSecond: 1_000_000_000
            )
        }
        #expect(throws: AudioRingConfigurationError.invalidChannelCount) {
            _ = try AudioSourceRingBuffer(
                role: .system,
                sampleRate: 48_000,
                channelCount: 0,
                hostTicksPerSecond: 1_000_000_000
            )
        }
        #expect(throws: AudioRingConfigurationError.invalidChannelCount) {
            _ = try AudioSourceRingBuffer(
                role: .system,
                sampleRate: 48_000,
                channelCount: 3,
                hostTicksPerSecond: 1_000_000_000
            )
        }
        #expect(throws: AudioRingConfigurationError.invalidHostTimebase) {
            _ = try AudioSourceRingBuffer(
                role: .system,
                sampleRate: 48_000,
                channelCount: 2,
                hostTicksPerSecond: 0
            )
        }
        for capacity in [Double.nan, .infinity, -Double.infinity, 0.049, 2.001] {
            #expect(throws: AudioRingConfigurationError.invalidCapacity) {
                _ = try AudioSourceRingBuffer(
                    role: .system,
                    sampleRate: 48_000,
                    channelCount: 2,
                    hostTicksPerSecond: 1_000_000_000,
                    capacitySeconds: capacity
                )
            }
        }
    }
    @Test func invalidFormatsAreRejectedAndCounted() throws {
        let ring = try RingTestSupport.makeRing()
        let samples = RingTestSupport.interleavedChunk(frameCount: 480, channelCount: 2, firstFrame: 0)
        let shortInterleaved = samples.withUnsafeBufferPointer {
            ring.write(interleaved: $0, frameCount: 481, hostTime: 1_000)
        }
        #expect(shortInterleaved.acceptedFrames == 0)
        #expect(shortInterleaved.reason == .invalidFormat)
        #expect(shortInterleaved.droppedFrames == 481)
        let singlePlanar = [Float](repeating: 0, count: 480)
        let mismatch = singlePlanar.withUnsafeBufferPointer {
            ring.write(planar: [$0], frameCount: 480, hostTime: 1_000)
        }
        #expect(mismatch.acceptedFrames == 0)
        #expect(mismatch.reason == .invalidFormat)
        #expect(ring.stats.lastDropReason == .invalidFormat)
        let valid = RingTestSupport.interleavedChunk(frameCount: 480, channelCount: 2, firstFrame: 0)
        let accepted = RingTestSupport.write(ring, interleaved: valid, frameCount: 480, channelCount: 2)
        #expect(accepted.acceptedFrames == 480)
        let block = ring.read(maxFrames: 480)
        #expect(block.block?.range.startSample == 961)
    }
    @Test func closedRingRejectsWrites() throws {
        let ring = try RingTestSupport.makeRing()
        let samples = RingTestSupport.interleavedChunk(frameCount: 480, channelCount: 2, firstFrame: 0)
        ring.requestClose()
        let result = RingTestSupport.write(ring, interleaved: samples, frameCount: 480, channelCount: 2)
        #expect(result.acceptedFrames == 0)
        #expect(result.droppedFrames == 480)
        #expect(result.reason == .closed)
        #expect(ring.isClosedAndEmpty)
    }
    @Test func statisticsExposeStagingAndDepthWithoutMutatingSharedState() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let samples = RingTestSupport.interleavedChunk(frameCount: 100, channelCount: 2, firstFrame: 0)
        _ = RingTestSupport.write(ring, interleaved: samples, frameCount: 100, channelCount: 2)
        let first = ring.stats
        let second = ring.stats
        #expect(first.acceptedFrames == 100)
        #expect(first.stagingFrames == 100)
        #expect(first.producerMaxDepth == 1)
        #expect(first.consumerMaxDepth == 0)
        #expect(first.reentrantRejects == 0)
        #expect(first.lastDropReason == nil)
        #expect(second.acceptedFrames == 100)
        #expect(second.stagingFrames == 100)
        #expect(ring.capacityFrames == 2_400)
    }
    @Test func closeDuringProducerKeepsDrainConsistent() throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.1)
        let chunk = RingTestSupport.interleavedChunk(frameCount: 480, channelCount: 2, firstFrame: 0)
        let producerDone = DispatchSemaphore(value: 0)
        let consumerDone = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "audio.ring.close", attributes: .concurrent)
        let stopBox = StopBox()
        let readCounter = LockedInt()
        let attemptedCounter = LockedInt()
        queue.async {
            var frame = 0
            while !stopBox.isStopped && frame < 200 * 480 {
                let result = chunk.withUnsafeBufferPointer {
                    ring.write(interleaved: $0, frameCount: 480, hostTime: 1_000)
                }
                frame += 480
                if result.reason == .closed {
                    break
                }
            }
            attemptedCounter.set(frame)
            producerDone.signal()
        }
        queue.async {
            var readFrames = 0
            while true {
                let result = ring.read(maxFrames: 480)
                readFrames += result.block?.frameCount ?? 0
                if result.isClosedAndEmpty && result.block == nil {
                    break
                }
            }
            readCounter.set(readFrames)
            consumerDone.signal()
        }
        usleep(1_000)
        stopBox.stop()
        ring.requestClose()
        guard producerDone.wait(timeout: .now() + 10) == .success else {
            Issue.record("producer timed out")
            return
        }
        _ = ring.finishProducing()
        guard consumerDone.wait(timeout: .now() + 10) == .success else {
            Issue.record("consumer timed out")
            return
        }
        let readFrames = readCounter.value
        let attempted = attemptedCounter.value
        #expect(readFrames == Int(ring.stats.acceptedFrames))
        #expect(readFrames + Int(ring.stats.droppedFrames) == attempted)
        #expect(ring.isClosedAndEmpty)
    }
}
private final class StopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
    func set(_ newValue: Int) {
        lock.lock()
        storedValue = newValue
        lock.unlock()
    }
}
