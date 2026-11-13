import Foundation
import Testing

@testable import CaptureCore

struct AudioMixPolicyTests {
    private func block(
        role: RecordingTrackRole = .system,
        channels: [[Float]],
        sampleRate: Int = 48_000,
        startSample: Int64 = 0,
        hostTime: UInt64 = 1_000
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

    @Test func twoSineWavesMixIntoUnityBoundedOutput() throws {
        let frames = 480
        let system = (0..<2).map { channel in
            (0..<frames).map { frame in
                0.3 * sin(Float(frame) * 0.05 + Float(channel) * 0.25)
            }
        }
        let microphone = [
            (0..<frames).map { frame in 0.2 * sin(Float(frame) * 0.07) }
        ]
        var policy = AudioMixPolicy(sampleRate: 48_000)

        let result = try policy.mix(
            system: block(channels: system),
            microphone: block(role: .microphone, channels: microphone),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.block.channelCount == 2)
        #expect(result.block.frameCount == frames)
        #expect(result.block.role == .mixed)
        #expect(result.block.sampleRate == 48_000)
        #expect(result.clippedSampleCount == 0)
        #expect(result.nonFiniteSampleCount == 0)
        #expect(result.block.channels.allSatisfy { $0.allSatisfy { abs($0) <= 1 } })

        for channel in 0..<2 {
            for frame in 0..<frames {
                let expected = system[channel][frame] + microphone[0][frame]
                #expect(abs(result.block.channels[channel][frame] - expected) < 0.000_1)
            }
        }
    }

    @Test func roleGainRampPersistsAcrossChunks() throws {
        var policy = AudioMixPolicy(sampleRate: 1_000, rampDurationSeconds: 0.01)
        let input = block(channels: constant(1, frames: 10), sampleRate: 1_000)

        let first = try policy.mix(
            system: input,
            microphone: nil,
            systemGainDB: -20,
            microphoneGainDB: 0,
            masterGainDB: 0
        )
        let second = try policy.mix(
            system: block(channels: constant(1, frames: 10), sampleRate: 1_000),
            microphone: nil,
            systemGainDB: -20,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(abs(first.block.channels[0][0] - 0.91) < 0.000_1)
        #expect(abs(first.block.channels[0][9] - 0.1) < 0.000_1)
        #expect(abs(second.block.channels[0][0] - 0.1) < 0.000_1)
        #expect(abs(second.block.channels[0][9] - 0.1) < 0.000_1)
    }

    @Test func microphoneGainRampIsIndependentFromSystemGain() throws {
        var policy = AudioMixPolicy(sampleRate: 1_000, rampDurationSeconds: 0.01)

        let system = try policy.mix(
            system: block(channels: constant(1, frames: 10), sampleRate: 1_000),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )
        let microphone = try policy.mix(
            system: nil,
            microphone: block(
                role: .microphone,
                channels: constant(1, frames: 10),
                sampleRate: 1_000
            ),
            systemGainDB: 0,
            microphoneGainDB: -20,
            masterGainDB: 0
        )

        #expect(system.block.channels[0][9] == 1)
        #expect(abs(microphone.block.channels[0][0] - 0.91) < 0.000_1)
        #expect(abs(microphone.block.channels[0][9] - 0.1) < 0.000_1)
    }

    @Test func outputGainRampPersistsAcrossChunks() throws {
        var policy = AudioMixPolicy(sampleRate: 1_000, rampDurationSeconds: 0.01)
        let input = block(channels: constant(1, frames: 10), sampleRate: 1_000)

        _ = try policy.mix(
            system: input,
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: -20
        )
        let second = try policy.mix(
            system: block(channels: constant(1, frames: 10), sampleRate: 1_000),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: -20
        )

        #expect(abs(second.block.channels[0][0] - 0.1) < 0.000_1)
    }

    @Test func monophonicMicrophoneMapsIntoStereoSystemOutput() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let system: [[Float]] = [[0.25, 0.25], [0.1, 0.1]]
        let microphone: [[Float]] = [[0.5, 0.5]]

        let result = try policy.mix(
            system: block(channels: system),
            microphone: block(role: .microphone, channels: microphone),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.block.channelCount == 2)
        #expect(abs(result.block.channels[0][0] - 0.75) < 0.000_1)
        #expect(abs(result.block.channels[1][0] - 0.6) < 0.000_1)
    }

    @Test func monophonicSystemAndMicrophoneStayMonophonic() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)

        let result = try policy.mix(
            system: block(channels: [[0.25, 0.25]]),
            microphone: block(role: .microphone, channels: [[0.5, 0.5]]),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.block.channelCount == 1)
        #expect(result.block.channels.count == 1)
        #expect(abs(result.block.channels[0][0] - 0.75) < 0.000_1)
    }

    @Test func nonFiniteSamplesBecomeZeroAndAreCounted() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let values: [Float] = [.nan, .infinity, -.infinity, 0.5, -0.25]

        let result = try policy.mix(
            system: block(channels: [values]),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.nonFiniteSampleCount == 3)
        #expect(result.block.channels[0][0] == 0)
        #expect(result.block.channels[0][1] == 0)
        #expect(result.block.channels[0][2] == 0)
        #expect(result.block.channels[0][3] == 0.5)
        #expect(result.block.channels[0][4] == -0.25)
        #expect(result.block.channels[0].allSatisfy { $0.isFinite })
        #expect(result.block.isSilence == false)
    }

    @Test func finiteOverRangeSamplesUseLimiterInsteadOfHardClipping() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let values: [Float] = [1.5, 1.5, 0.5, 0.5]

        let result = try policy.mix(
            system: block(channels: [values]),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.clippedSampleCount == 2)
        #expect(result.nonFiniteSampleCount == 0)
        #expect(result.block.channels[0].allSatisfy { abs($0) <= 1 })
        #expect(result.block.channels[0][0] > 0.8)
        #expect(result.block.channels[0][2] < 0.5)
        #expect(result.block.channels[0][2] > 0.2)
    }

    @Test func limiterGainStatePersistsAcrossChunks() throws {
        var policy = AudioMixPolicy(sampleRate: 1_000)

        _ = try policy.mix(
            system: block(channels: [[1.5, 1.5]], sampleRate: 1_000),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )
        let second = try policy.mix(
            system: block(channels: [[0.5, 0.5]], sampleRate: 1_000),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(second.block.channels[0][0] < 0.5)
        #expect(second.block.channels[0][0] > 0.2)
    }

    @Test func silentInputProducesSilenceWithoutClipping() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)

        let result = try policy.mix(
            system: block(channels: constant(0, frames: 480, channels: 2)),
            microphone: block(role: .microphone, channels: constant(0, frames: 480)),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.block.isSilence)
        #expect(result.clippedSampleCount == 0)
        #expect(result.nonFiniteSampleCount == 0)
        #expect(result.block.channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func invalidInputsThrowPreciseErrors() {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let stereo = block(channels: constant(0.1, frames: 4, channels: 2))
        #expect(throws: AudioMixError.noInput) {
            _ = try policy.mix(
                system: nil,
                microphone: nil,
                systemGainDB: 0,
                microphoneGainDB: 0,
                masterGainDB: 0
            )
        }
        #expect(throws: AudioMixError.incompatibleSampleRate) {
            _ = try policy.mix(
                system: stereo,
                microphone: block(
                    role: .microphone,
                    channels: constant(0.1, frames: 4),
                    sampleRate: 44_100
                ),
                systemGainDB: 0,
                microphoneGainDB: 0,
                masterGainDB: 0
            )
        }
        #expect(throws: AudioMixError.invalidFrameCount) {
            _ = try policy.mix(
                system: stereo,
                microphone: block(role: .microphone, channels: constant(0.1, frames: 5)),
                systemGainDB: 0,
                microphoneGainDB: 0,
                masterGainDB: 0
            )
        }
        #expect(throws: AudioMixError.incompatibleRange) {
            _ = try policy.mix(
                system: stereo,
                microphone: block(
                    role: .microphone,
                    channels: constant(0.1, frames: 4),
                    startSample: 8
                ),
                systemGainDB: 0,
                microphoneGainDB: 0,
                masterGainDB: 0
            )
        }
        #expect(throws: AudioMixError.invalidFrameCount) {
            _ = try policy.mix(
                system: block(channels: []),
                microphone: nil,
                systemGainDB: 0,
                microphoneGainDB: 0,
                masterGainDB: 0
            )
        }
        #expect(throws: AudioMixError.incompatibleRange) {
            _ = try policy.mix(
                system: block(channels: constant(0.1, frames: 4, channels: 3)),
                microphone: nil,
                systemGainDB: 0,
                microphoneGainDB: 0,
                masterGainDB: 0
            )
        }
    }

    @Test func nonFiniteGainParametersDoNotTrapOrProduceNonFiniteOutput() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)

        let result = try policy.mix(
            system: block(channels: [[0.25, 0.25]]),
            microphone: nil,
            systemGainDB: .nan,
            microphoneGainDB: .infinity,
            masterGainDB: -.infinity
        )

        #expect(result.block.channels[0].allSatisfy { $0.isFinite })
        #expect(result.block.channels[0].allSatisfy { abs($0) <= 1 })
    }
}

struct AudioMixPolicyEdgeTests {
    private func block(
        role: RecordingTrackRole = .system,
        channels: [[Float]],
        sampleRate: Int = 48_000,
        startSample: Int64 = 0,
        hostTime: UInt64 = 1_000
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

    @Test func twoSourceNaNOnlyZeroesBadInputAndCountsOnce() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let result = try policy.mix(
            system: block(channels: [[.nan, 0.5]]),
            microphone: block(role: .microphone, channels: [[0.5, 0.5]]),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.nonFiniteSampleCount == 1)
        #expect(result.block.channels[0][0] == 0.5)
        #expect(abs(result.block.channels[0][1] - 1) < 0.000_1)
        #expect(result.block.channels[0].allSatisfy { $0.isFinite })
    }

    @Test func bothSourcesNaNCountBothPhysicalInputs() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let result = try policy.mix(
            system: block(channels: [[.nan]]),
            microphone: block(role: .microphone, channels: [[.nan]]),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.nonFiniteSampleCount == 2)
        #expect(result.block.channels[0][0] == 0)
        #expect(result.block.isSilence)
    }

    @Test func monoFanoutCountsOnePhysicalNaN() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let result = try policy.mix(
            system: block(channels: [[.nan, 0.5]]),
            microphone: block(
                role: .microphone,
                channels: [[0.1, 0.1], [0.2, 0.2]]
            ),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.nonFiniteSampleCount == 1)
        #expect(abs(result.block.channels[0][0] - 0.1) < 0.000_1)
        #expect(abs(result.block.channels[1][0] - 0.2) < 0.000_1)
    }

    @Test func twoSourceOverunityUsesLimiterAndBoundedOutput() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let result = try policy.mix(
            system: block(channels: [[0.8]]),
            microphone: block(role: .microphone, channels: [[0.8]]),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.clippedSampleCount == 1)
        #expect(result.block.channels[0][0] == 1)
        #expect(result.block.channels[0].allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func finiteExtremesSaturateWithoutBecomingSilence() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let result = try policy.mix(
            system: block(channels: [[.greatestFiniteMagnitude]]),
            microphone: block(role: .microphone, channels: [[.greatestFiniteMagnitude]]),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.nonFiniteSampleCount == 0)
        #expect(result.block.channels[0].allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(result.block.channels[0][0] > 0.9)
    }

    @Test func routeDisableAndReenablePreservesRampState() throws {
        var policy = AudioMixPolicy(sampleRate: 1_000, rampDurationSeconds: 0.01)
        _ = try policy.mix(
            system: block(channels: constant(1, frames: 10), sampleRate: 1_000),
            microphone: nil,
            systemGainDB: -20,
            microphoneGainDB: 0,
            masterGainDB: 0
        )
        _ = try policy.mix(
            system: nil,
            microphone: block(role: .microphone, channels: [[0, 0]], sampleRate: 1_000),
            systemGainDB: -20,
            microphoneGainDB: 0,
            masterGainDB: 0
        )
        let reenabled = try policy.mix(
            system: block(channels: constant(1, frames: 10), sampleRate: 1_000),
            microphone: nil,
            systemGainDB: -20,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(abs(reenabled.block.channels[0][0] - 0.1) < 0.000_1)
    }

    @Test func midRampTargetChangeStartsFromCurrentGain() throws {
        var policy = AudioMixPolicy(sampleRate: 1_000, rampDurationSeconds: 0.01)
        _ = try policy.mix(
            system: block(channels: constant(1, frames: 5), sampleRate: 1_000),
            microphone: nil,
            systemGainDB: -20,
            microphoneGainDB: 0,
            masterGainDB: 0
        )
        let changed = try policy.mix(
            system: block(channels: constant(1, frames: 5), sampleRate: 1_000),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(abs(changed.block.channels[0][0] - 0.595) < 0.000_1)
    }

    @Test func hostAndRangePropagateToMixedBlock() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let result = try policy.mix(
            system: block(channels: [[0.1, 0.2]], startSample: 123, hostTime: 456),
            microphone: block(
                role: .microphone,
                channels: [[0.3, 0.4]],
                startSample: 123,
                hostTime: 999
            ),
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.block.range.startSample == 123)
        #expect(result.block.range.sampleCount == 2)
        #expect(result.block.hostTime == 456)
    }

    @Test func defaultRampIsEightMillisecondsAtFortyEightKilohertz() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let result = try policy.mix(
            system: block(channels: constant(1, frames: 384)),
            microphone: nil,
            systemGainDB: -20,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.block.channels[0][0] > 0.99)
        #expect(abs(result.block.channels[0][383] - 0.1) < 0.000_1)
    }

    @Test func malformedBlocksThrowPreciseErrors() {
        var policy = AudioMixPolicy(sampleRate: 48_000)
        let wrongChannelCount = AudioPCMBlock(
            role: .system,
            range: SampleRange(startSample: 0, sampleCount: 2),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 2,
            hostTime: 0,
            channels: [[0, 1]],
            isSilence: false
        )
        let wrongChannelLength = AudioPCMBlock(
            role: .system,
            range: SampleRange(startSample: 0, sampleCount: 2),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            hostTime: 0,
            channels: [[0]],
            isSilence: false
        )
        let wrongRangeCount = AudioPCMBlock(
            role: .system,
            range: SampleRange(startSample: 0, sampleCount: 1),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 2,
            hostTime: 0,
            channels: [[0, 1]],
            isSilence: false
        )

        for malformed in [wrongChannelCount, wrongChannelLength, wrongRangeCount] {
            #expect(throws: AudioMixError.invalidFrameCount) {
                _ = try policy.mix(
                    system: malformed,
                    microphone: nil,
                    systemGainDB: 0,
                    microphoneGainDB: 0,
                    masterGainDB: 0
                )
            }
        }
    }

    @Test func hugeRampDurationDoesNotTrap() throws {
        var policy = AudioMixPolicy(sampleRate: 48_000, rampDurationSeconds: 1e300)
        let result = try policy.mix(
            system: block(channels: [[0.25, 0.25]]),
            microphone: nil,
            systemGainDB: 0,
            microphoneGainDB: 0,
            masterGainDB: 0
        )

        #expect(result.block.channels[0].allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func nonPositivePolicyRateThrowsInsteadOfMixing() {
        var policy = AudioMixPolicy(sampleRate: 0)
        #expect(throws: AudioMixError.incompatibleSampleRate) {
            _ = try policy.mix(
                system: block(channels: [[0.25]], sampleRate: 0),
                microphone: nil,
                systemGainDB: 0,
                microphoneGainDB: 0,
                masterGainDB: 0
            )
        }
    }
}
