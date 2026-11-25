import Foundation
import Testing

@testable import CaptureCore

struct AudioDriftResamplerTests {
    private func block(
        role: RecordingTrackRole = .microphone,
        channels: [[Float]],
        sampleRate: Int,
        startSample: Int64,
        hostTime: UInt64 = 0
    ) -> AudioPCMBlock {
        AudioPCMBlock(
            role: role,
            range: SampleRange(startSample: startSample, sampleCount: Int64(channels.first?.count ?? 0)),
            sampleRate: sampleRate,
            channelCount: channels.count,
            frameCount: channels.first?.count ?? 0,
            hostTime: hostTime,
            channels: channels,
            isSilence: channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
        )
    }

    private func constant(_ value: Float, frames: Int, channels: Int = 1) -> [[Float]] {
        (0..<channels).map { _ in [Float](repeating: value, count: frames) }
    }

    private func collect(
        _ resampler: AudioDriftResampler,
        blocks: [AudioPCMBlock]
    ) throws -> (blocks: [AudioPCMBlock], batches: [ResampleBatch]) {
        var output: [AudioPCMBlock] = []
        var batches: [ResampleBatch] = []
        for block in blocks {
            let batch = try resampler.process(block)
            batches.append(batch)
            output.append(contentsOf: batch.blocks)
        }
        let tail = try resampler.flush()
        batches.append(tail)
        output.append(contentsOf: tail.blocks)
        return (output, batches)
    }

    @Test func fortyEightKhzPassesSamplesAndTimelineThrough() throws {
        var samples: [[Float]] = [[], []]
        for frame in 0..<480 {
            samples[0].append(Float(frame))
            samples[1].append(Float(frame) * -0.5)
        }
        let resampler = AudioDriftResampler(
            inputSampleRate: 48_000,
            targetWatermarkSeconds: 0.02,
            maxCorrectionPPM: 300
        )

        let batch = try resampler.process(block(channels: samples, sampleRate: 48_000, startSample: 0))
        let tail = try resampler.flush()

        #expect(batch.blocks.count == 1)
        #expect(tail.blocks.isEmpty)
        let output = try #require(batch.blocks.first)
        #expect(output.frameCount == 480)
        #expect(output.sampleRate == 48_000)
        #expect(output.channelCount == 2)
        #expect(output.range.startSample == 0)
        #expect(output.channels[0][0] == 0)
        #expect(output.channels[0][479] == 479)
        #expect(output.channels[1][479] == -239.5)
        #expect(batch.consumedFrames == 480)
    }

    @Test func convertsFortyFourOneToFortyEightWithExactDuration() throws {
        let frames = 4_410
        let samples = (0..<2).map { channel in
            (0..<frames).map { frame in
                sin(Float(frame) * 0.01 + Float(channel) * 0.2)
            }
        }
        let resampler = AudioDriftResampler(
            inputSampleRate: 44_100,
            targetWatermarkSeconds: 0.05,
            maxCorrectionPPM: 0
        )

        let result = try collect(
            resampler,
            blocks: [block(channels: samples, sampleRate: 44_100, startSample: 0)]
        )

        #expect(result.blocks.count == 10)
        #expect(result.blocks.allSatisfy { $0.frameCount == 480 })
        #expect(result.blocks.allSatisfy { $0.sampleRate == 48_000 })
        #expect(result.batches.reduce(0) { $0 + $1.consumedFrames } == frames)
        for index in result.blocks.indices {
            #expect(result.blocks[index].range.startSample == Int64(index * 480))
        }
    }

    @Test func flushEmitsShortTailWithEveryInputFrame() throws {
        let samples = (0..<100).map { Float($0) }
        let resampler = AudioDriftResampler(
            inputSampleRate: 48_000,
            targetWatermarkSeconds: 0.02,
            maxCorrectionPPM: 0
        )

        let batch = try resampler.process(
            block(channels: [samples], sampleRate: 48_000, startSample: 0)
        )
        let tail = try resampler.flush()

        #expect(batch.blocks.isEmpty)
        #expect(tail.blocks.count == 1)
        let output = try #require(tail.blocks.first)
        #expect(output.frameCount == 100)
        #expect(output.range.startSample == 0)
        #expect(output.channels[0] == samples)
    }

    @Test func sourceRangeGapBecomesEqualLengthSilence() throws {
        let first = [Float](repeating: 0.25, count: 100)
        let second = [Float](repeating: -0.5, count: 100)
        let resampler = AudioDriftResampler(
            inputSampleRate: 48_000,
            targetWatermarkSeconds: 0.02,
            maxCorrectionPPM: 0
        )

        _ = try resampler.process(
            block(channels: [first], sampleRate: 48_000, startSample: 0)
        )
        let batch = try resampler.process(
            block(channels: [second], sampleRate: 48_000, startSample: 200)
        )
        let tail = try resampler.flush()

        #expect(batch.gapFrames == 100)
        let output = try #require((batch.blocks + tail.blocks).last)
        #expect(output.frameCount == 300)
        #expect(output.channels[0][0..<100] == first[...])
        #expect(output.channels[0][100..<200].allSatisfy { $0 == 0 })
        #expect(output.channels[0][200..<300] == second[...])
    }

    @Test func positiveCorrectionIsGradualAndBounded() throws {
        let resampler = AudioDriftResampler(
            inputSampleRate: 44_100,
            targetWatermarkSeconds: 0.005,
            maxCorrectionPPM: 300
        )
        let frames = 480
        let samples = (0..<frames).map { Float($0 % 17) }

        let first = try resampler.process(
            block(channels: [samples], sampleRate: 44_100, startSample: 0)
        )
        #expect(first.correctionPPM > 0)
        #expect(first.correctionPPM <= 300)

        var previous = first.correctionPPM
        for index in 1..<8 {
            let batch = try resampler.process(
                block(
                    channels: [samples],
                    sampleRate: 44_100,
                    startSample: Int64(index * frames)
                )
            )
            #expect(batch.correctionPPM <= 300)
            #expect(abs(batch.correctionPPM - previous) <= 20)
            previous = batch.correctionPPM
        }
        #expect(previous > first.correctionPPM)
    }

    @Test func negativeCorrectionIsBoundedForLowWatermark() throws {
        let resampler = AudioDriftResampler(
            inputSampleRate: 48_000,
            targetWatermarkSeconds: 0.5,
            maxCorrectionPPM: 100
        )
        let batch = try resampler.process(
            block(
                channels: [[Float](repeating: 0.1, count: 480)],
                sampleRate: 48_000,
                startSample: 0
            )
        )
        #expect(batch.correctionPPM < 0)
        #expect(batch.correctionPPM >= -100)
        #expect(batch.watermarkSeconds >= 0)
    }

    @Test(arguments: [100, 300])
    func correctionKeepsOutputDurationNearNominal(maxPPM: Int) throws {
        let inputRate = 44_100
        let frames = 4_410
        let sample = [Float](repeating: 0.1, count: frames)
        let resampler = AudioDriftResampler(
            inputSampleRate: inputRate,
            targetWatermarkSeconds: 0.05,
            maxCorrectionPPM: maxPPM
        )

        var outputFrames = 0
        var consumed = 0
        for index in 0..<20 {
            let batch = try resampler.process(
                block(
                    channels: [sample],
                    sampleRate: inputRate,
                    startSample: Int64(index * frames)
                )
            )
            outputFrames += batch.blocks.reduce(0) { $0 + $1.frameCount }
            consumed += batch.consumedFrames
            #expect(abs(batch.correctionPPM) <= Double(maxPPM))
        }
        let tail = try resampler.flush()
        outputFrames += tail.blocks.reduce(0) { $0 + $1.frameCount }

        #expect(consumed == frames * 20)
        #expect(abs(outputFrames - 96_000) < 1_000)
        #expect(abs(tail.correctionPPM) <= Double(maxPPM))
    }

    @Test func processAfterFlushThrows() throws {
        let resampler = AudioDriftResampler(
            inputSampleRate: 48_000,
            targetWatermarkSeconds: 0.02,
            maxCorrectionPPM: 0
        )
        _ = try resampler.flush()
        #expect(throws: AudioResampleError.alreadyFlushed) {
            try resampler.process(
                block(channels: [[0.1]], sampleRate: 48_000, startSample: 0)
            )
        }
    }

    @Test func fortyFourOneGapIsPublishedAsSessionFrames() throws {
        let resampler = AudioDriftResampler(
            inputSampleRate: 44_100,
            targetWatermarkSeconds: 0.01,
            maxCorrectionPPM: 0
        )
        _ = try resampler.process(
            block(
                channels: [[Float](repeating: 0.1, count: 441)],
                sampleRate: 44_100,
                startSample: 0
            )
        )
        let gap = try resampler.process(
            block(
                channels: [[Float](repeating: 0.2, count: 441)],
                sampleRate: 44_100,
                startSample: 882
            )
        )

        #expect(gap.gapFrames == 441)
        #expect(gap.sessionGapFrames == 480)
    }

    @Test func nondivisibleGapCarryRemainsConsistent() {
        let resampler = AudioDriftResampler(
            inputSampleRate: 44_100,
            targetWatermarkSeconds: 0.01,
            maxCorrectionPPM: 0
        )
        var total = 0
        for _ in 0..<100 {
            total += resampler.sessionGapFrames(forInputFrames: 100)
        }
        #expect(total == 10_884)
    }

    @Test func largeGapKeepsWholeSessionGapOnFirstBatch() throws {
        let resampler = AudioDriftResampler(
            inputSampleRate: 44_100,
            targetWatermarkSeconds: 0.01,
            maxCorrectionPPM: 0
        )
        _ = try resampler.process(
            block(
                channels: [[Float](repeating: 0.1, count: 441)],
                sampleRate: 44_100,
                startSample: 0
            )
        )
        let batch = try resampler.process(
            block(
                channels: [[Float](repeating: 0.2, count: 441)],
                sampleRate: 44_100,
                startSample: 1_323
            )
        )

        #expect(batch.gapFrames == 882)
        #expect(batch.sessionGapFrames == 960)
        #expect(batch.blocks.isEmpty == false)
    }

    @Test func mismatchedInputRateIsRejected() {
        let resampler = AudioDriftResampler(
            inputSampleRate: 44_100,
            targetWatermarkSeconds: 0.02,
            maxCorrectionPPM: 0
        )
        #expect(throws: AudioResampleError.incompatibleSampleRate) {
            try resampler.process(
                block(channels: [[0.1]], sampleRate: 48_000, startSample: 0)
            )
        }
    }
}
