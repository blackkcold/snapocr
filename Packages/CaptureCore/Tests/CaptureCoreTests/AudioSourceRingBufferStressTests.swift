import Foundation
import Testing

@testable import CaptureCore

struct AudioSourceRingBufferStressTests {
    @Test func twoThreadStressPassesTwentyRegisteredRepetitions() throws {
        // CI runs a short smoke version; the full 20 repetitions stay local.
        let iterations = ProcessInfo.processInfo.environment["CI"] == nil ? 20 : 2
        for iteration in 1...iterations {
            try runStressIteration(iteration)
        }
    }
    private func runStressIteration(_ iteration: Int) throws {
        let ring = try RingTestSupport.makeRing(capacitySeconds: 0.05)
        let producerDone = DispatchSemaphore(value: 0)
        let consumerDone = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "audio.ring.stress", attributes: .concurrent)
        let state = StressState()
        let producerFinished = LockedInt()
        let totalFrames = 400_000
        queue.async {
            Self.produce(
                ring: ring,
                state: state,
                finished: producerFinished,
                iteration: iteration,
                done: producerDone
            )
        }
        queue.async {
            Self.consume(
                ring: ring,
                state: state,
                producerFinished: producerFinished,
                done: consumerDone
            )
        }
        guard producerDone.wait(timeout: .now() + 30) == .success else {
            Issue.record("iteration \(iteration): producer timed out")
            return
        }
        guard consumerDone.wait(timeout: .now() + 30) == .success else {
            Issue.record("iteration \(iteration): consumer timed out")
            return
        }
        #expect(state.failure == nil, "iteration \(iteration): \(state.failure ?? "")")
        #expect(
            state.readFrames == state.producedFrames - Int(ring.stats.droppedFrames),
            "iteration \(iteration): read \(state.readFrames) produced \(state.producedFrames)"
        )
        #expect(state.readFrames + Int(ring.stats.droppedFrames) == totalFrames)
        #expect(state.gaps == Int(ring.stats.gapFrames))
        #expect(ring.isClosedAndEmpty)
    }
    private static func produce(
        ring: AudioSourceRingBuffer,
        state: StressState,
        finished: LockedInt,
        iteration: Int,
        done: DispatchSemaphore
    ) {
        let totalFrames = 400_000
        var generator = LinearCongruential(seed: UInt64(iteration))
        var frame = 0
        while frame < totalFrames {
            let requested = min(generator.next(in: 1...960), totalFrames - frame)
            var interleaved = [Float](repeating: 0, count: requested * 2)
            for offset in 0..<requested {
                let value = Float((frame + offset) % 997)
                interleaved[offset * 2] = value
                interleaved[offset * 2 + 1] = -value
            }
            let result = interleaved.withUnsafeBufferPointer {
                ring.write(interleaved: $0, frameCount: requested, hostTime: 1_000)
            }
            if result.acceptedFrames == 0 && result.reason == .reentrantProducer {
                state.record("producer reentered")
                break
            }
            frame += requested
        }
        state.producedFrames = frame
        _ = ring.finishProducing()
        ring.requestClose()
        finished.set(1)
        done.signal()
    }
    private static func consume(
        ring: AudioSourceRingBuffer,
        state: StressState,
        producerFinished: LockedInt,
        done: DispatchSemaphore
    ) {
        var generator = LinearCongruential(seed: 2_026)
        var readFrames = 0
        var cursor = StressCursor()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let result = ring.read(maxFrames: generator.next(in: 1...700))
            if let block = result.block {
                guard
                    validate(
                        block: block,
                        gap: result.gapFrames,
                        state: state,
                        cursor: &cursor
                    )
                else {
                    break
                }
                readFrames += block.frameCount
            } else {
                cursor.gaps += result.gapFrames
            }
            if result.isClosedAndEmpty && result.block == nil {
                break
            }
            if result.block == nil {
                if producerFinished.value == 1 {
                    _ = ring.finishProducing()
                }
                sched_yield()
            }
        }
        state.readFrames = readFrames
        state.gaps = cursor.gaps
        done.signal()
    }
    private static func validate(
        block: AudioPCMBlock,
        gap: Int,
        state: StressState,
        cursor: inout StressCursor
    ) -> Bool {
        if cursor.hasBlock {
            if gap == 0 && block.range.startSample != cursor.lastEnd {
                state.record("range discontinuity at \(block.range.startSample) vs \(cursor.lastEnd)")
                return false
            }
            if gap > 0 && block.range.startSample != cursor.lastEnd + Int64(gap) {
                state.record("gap/range mismatch at \(block.range.startSample)")
                return false
            }
        } else if gap > 0 {
            state.record("first block carried an unexpected gap")
            return false
        }
        cursor.gaps += gap
        for index in 0..<block.frameCount {
            let expected = Float((Int(block.range.startSample) + index) % 997)
            if block.channels[0][index] != expected || block.channels[1][index] != -expected {
                state.record("sample corruption at \(Int(block.range.startSample) + index)")
                return false
            }
        }
        cursor.lastEnd = block.range.startSample + Int64(block.frameCount)
        cursor.hasBlock = true
        return true
    }
}

private struct StressCursor {
    var lastEnd: Int64 = 0
    var hasBlock = false
    var gaps = 0
}
private final class StressState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: String?
    var producedFrames = 0
    var readFrames = 0
    var gaps = 0
    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }
    func record(_ message: String) {
        lock.lock()
        if storedFailure == nil {
            storedFailure = message
        }
        lock.unlock()
    }
}
private struct LinearCongruential {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }
    mutating func next(in range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int((state >> 33) % span)
    }
}
