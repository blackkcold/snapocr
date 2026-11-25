import Foundation

// The public `masterGainDB` label is part of the frozen Task 4 interface.

/// One mixed PCM block plus limiter diagnostics.
public struct AudioMixResult: Sendable {
    /// The owned mixed block at the policy's sample rate.
    public let block: AudioPCMBlock
    /// Finite samples whose magnitude exceeded unity and entered the limiter.
    public let clippedSampleCount: Int
    /// Non-finite input samples replaced with silence.
    public let nonFiniteSampleCount: Int

    /// Creates a mix result.
    ///
    /// - Parameters:
    ///   - block: Owned mixed block.
    ///   - clippedSampleCount: Finite over-range samples.
    ///   - nonFiniteSampleCount: Non-finite samples replaced with zero.
    public init(block: AudioPCMBlock, clippedSampleCount: Int, nonFiniteSampleCount: Int) {
        self.block = block
        self.clippedSampleCount = clippedSampleCount
        self.nonFiniteSampleCount = nonFiniteSampleCount
    }
}

/// A validation failure while mixing audio roles.
public enum AudioMixError: Error, Equatable {
    /// Neither a system nor a microphone block was supplied.
    case noInput
    /// An input block does not match the policy's sample rate.
    case incompatibleSampleRate
    /// Input ranges, channels, or layouts cannot be combined.
    case incompatibleRange
    /// The frame count is zero, negative, or differs between inputs.
    case invalidFrameCount
}

private struct AudioMixSources {
    let system: AudioPCMBlock?
    let microphone: AudioPCMBlock?
}

private struct AudioMixGains {
    let systemDB: Float
    let microphoneDB: Float
    let outputDB: Float
}

private struct RenderedMix {
    let channels: [[Float]]
    let clipped: Int
    let nonFinite: Int
}

/// Mixes system and microphone blocks with independent ramped gains and a limiter.
///
/// Role gains and the master gain each keep their own ramp state across calls.
/// Gain changes therefore glide over `rampDurationSeconds` instead of restarting
/// at every chunk. The limiter also keeps its release envelope across chunks.
/// The policy is a value type; a producer owns one mutable instance per stream.
public struct AudioMixPolicy: Sendable {
    private let sampleRate: Int
    private let rampDurationSeconds: Double
    private let rampFrameCount: Int
    private let limiterReleaseStep: Float

    private var systemGain: Float = 1
    private var microphoneGain: Float = 1
    private var outputGain: Float = 1
    private var limiterGain: Float = 1

    /// Creates a mix policy.
    ///
    /// - Parameters:
    ///   - sampleRate: Output and input sample rate in hertz.
    ///   - rampDurationSeconds: Gain glide duration; defaults to eight milliseconds.
    ///     Finite values are clamped to `0...1` second; non-finite values use the
    ///     default. A non-positive `sampleRate` is rejected when ``mix`` runs.
    public init(sampleRate: Int, rampDurationSeconds: Double = 0.008) {
        self.sampleRate = sampleRate
        let duration =
            rampDurationSeconds.isFinite
            ? min(1.0, max(0, rampDurationSeconds))
            : 0.008
        self.rampDurationSeconds = duration
        let safeRate = min(max(1, sampleRate), 768_000)
        let rampFrames = Int((Double(safeRate) * duration).rounded())
        self.rampFrameCount = max(1, rampFrames)
        let releaseFrames = max(1, Int(Double(safeRate) * 0.25))
        self.limiterReleaseStep = 1 / Float(releaseFrames)
    }

    /// Mixes one block from each available role.
    ///
    /// A monophonic role is duplicated into a stereophonic output; stereophonic
    /// inputs are never downmixed. Non-finite samples become zero and are
    /// counted. Finite over-range samples are attenuated by the limiter rather
    /// than being hard-clipped.
    ///
    /// - Parameters:
    ///   - system: System-audio block, or `nil` when that role is inactive.
    ///   - microphone: Microphone block, or `nil` when that role is inactive.
    ///   - systemGainDB: Target system-role gain in decibels.
    ///   - microphoneGainDB: Target microphone-role gain in decibels.
    ///   - masterGainDB: Target master gain in decibels.
    /// - Returns: The mixed block and limiter diagnostics.
    /// - Throws: ``AudioMixError`` when the inputs cannot be combined.
    public mutating func mix(
        system: AudioPCMBlock?,
        microphone: AudioPCMBlock?,
        systemGainDB: Float,
        microphoneGainDB: Float,
        // swiftlint:disable:next inclusive_language
        masterGainDB: Float
    ) throws -> AudioMixResult {
        guard system != nil || microphone != nil else {
            throw AudioMixError.noInput
        }
        guard sampleRate > 0 else {
            throw AudioMixError.incompatibleSampleRate
        }
        let frameCount = try validate(system: system, microphone: microphone)
        let outputChannels = max(system?.channelCount ?? 0, microphone?.channelCount ?? 0)
        let rangeStart = system?.range.startSample ?? microphone?.range.startSample ?? 0
        let hostTime = system?.hostTime ?? microphone?.hostTime ?? 0
        let rendered = render(
            sources: AudioMixSources(system: system, microphone: microphone),
            frameCount: frameCount,
            outputChannels: outputChannels,
            gains: AudioMixGains(
                systemDB: systemGainDB,
                microphoneDB: microphoneGainDB,
                outputDB: masterGainDB
            )
        )
        let isSilence = rendered.channels.allSatisfy { $0.allSatisfy { $0 == 0 } }
        let block = AudioPCMBlock(
            role: .mixed,
            range: SampleRange(startSample: rangeStart, sampleCount: Int64(frameCount)),
            sampleRate: sampleRate,
            channelCount: outputChannels,
            frameCount: frameCount,
            hostTime: hostTime,
            channels: rendered.channels,
            isSilence: isSilence
        )
        return AudioMixResult(
            block: block,
            clippedSampleCount: rendered.clipped,
            nonFiniteSampleCount: rendered.nonFinite
        )
    }

    private mutating func render(
        sources: AudioMixSources,
        frameCount: Int,
        outputChannels: Int,
        gains: AudioMixGains
    ) -> RenderedMix {
        let rampStep = 1 / Float(max(1, rampFrameCount))
        let systemTarget = Self.linearGain(gains.systemDB) ?? systemGain
        let microphoneTarget = Self.linearGain(gains.microphoneDB) ?? microphoneGain
        let outputTarget = Self.linearGain(gains.outputDB) ?? outputGain
        let systemStep = (systemTarget - systemGain) * rampStep
        let microphoneStep = (microphoneTarget - microphoneGain) * rampStep
        let outputStep = (outputTarget - outputGain) * rampStep
        var channels = (0..<outputChannels).map { _ in [Float](repeating: 0, count: frameCount) }
        var frameSamples = [Float](repeating: 0, count: outputChannels)
        var clipped = 0
        var nonFinite = 0

        for frame in 0..<frameCount {
            advance(&systemGain, toward: systemTarget, step: systemStep)
            advance(&microphoneGain, toward: microphoneTarget, step: microphoneStep)
            advance(&outputGain, toward: outputTarget, step: outputStep)
            nonFinite += countNonFiniteInputs(in: sources.system, frame: frame)
            nonFinite += countNonFiniteInputs(in: sources.microphone, frame: frame)
            var peak: Float = 0
            for channel in 0..<outputChannels {
                frameSamples[channel] = finiteSample(
                    sources: sources,
                    channel: channel,
                    outputChannelCount: outputChannels,
                    frame: frame
                )
                if abs(frameSamples[channel]) > 1 {
                    clipped += 1
                }
                peak = max(peak, abs(frameSamples[channel]))
            }
            updateLimiter(peak: peak)
            for channel in 0..<outputChannels {
                channels[channel][frame] = Self.clamped(frameSamples[channel] * limiterGain)
            }
        }
        return RenderedMix(channels: channels, clipped: clipped, nonFinite: nonFinite)
    }

    private func finiteSample(
        sources: AudioMixSources,
        channel: Int,
        outputChannelCount: Int,
        frame: Int
    ) -> Float {
        var sum: Float = 0
        if let system = sources.system {
            sum +=
                Self.sanitizedSample(
                    from: system,
                    channel: channel,
                    outputChannelCount: outputChannelCount,
                    frame: frame
                ) * systemGain
        }
        if let microphone = sources.microphone {
            sum +=
                Self.sanitizedSample(
                    from: microphone,
                    channel: channel,
                    outputChannelCount: outputChannelCount,
                    frame: frame
                ) * microphoneGain
        }
        sum *= outputGain
        return Self.saturatedFinite(sum)
    }

    private func countNonFiniteInputs(in block: AudioPCMBlock?, frame: Int) -> Int {
        guard let block else {
            return 0
        }
        if block.channelCount == 1 {
            return block.channels[0][frame].isFinite ? 0 : 1
        }
        return (0..<block.channelCount).reduce(0) { count, channel in
            count + (block.channels[channel][frame].isFinite ? 0 : 1)
        }
    }

    private mutating func updateLimiter(peak: Float) {
        if peak > 1 {
            limiterGain = min(limiterGain, 1 / peak)
        } else {
            limiterGain = min(1, limiterGain + limiterReleaseStep)
        }
    }

    private func validate(system: AudioPCMBlock?, microphone: AudioPCMBlock?) throws -> Int {
        let inputs = [system, microphone].compactMap { $0 }
        for input in inputs {
            guard input.sampleRate == sampleRate else {
                throw AudioMixError.incompatibleSampleRate
            }
            guard input.frameCount > 0,
                input.channels.count == input.channelCount,
                input.channels.allSatisfy({ $0.count == input.frameCount }),
                input.range.sampleCount == Int64(input.frameCount)
            else {
                throw AudioMixError.invalidFrameCount
            }
            guard input.channelCount == 1 || input.channelCount == 2 else {
                throw AudioMixError.incompatibleRange
            }
        }
        if let system, let microphone {
            guard system.frameCount == microphone.frameCount else {
                throw AudioMixError.invalidFrameCount
            }
            guard system.range.startSample == microphone.range.startSample else {
                throw AudioMixError.incompatibleRange
            }
        }
        return inputs[0].frameCount
    }

    private func advance(_ current: inout Float, toward target: Float, step: Float) {
        let next = current + step
        if step == 0 || (step > 0 && next >= target) || (step < 0 && next <= target) {
            current = target
        } else {
            current = next
        }
    }

    private static func sanitizedSample(
        from block: AudioPCMBlock,
        channel: Int,
        outputChannelCount: Int,
        frame: Int
    ) -> Float {
        let raw: Float
        if block.channelCount > 1 {
            raw = block.channels[min(channel, block.channelCount - 1)][frame]
        } else {
            raw = block.channels[0][frame]
        }
        return raw.isFinite ? raw : 0
    }

    private static func saturatedFinite(_ value: Float) -> Float {
        guard !value.isFinite else {
            return value
        }
        return value.sign == .minus ? -Float.greatestFiniteMagnitude : Float.greatestFiniteMagnitude
    }

    private static func linearGain(_ decibels: Float) -> Float? {
        guard decibels.isFinite else {
            return nil
        }
        let exponent = min(24, max(-120, decibels)) / 20
        return pow(10, exponent)
    }

    private static func clamped(_ sample: Float) -> Float {
        min(1, max(-1, sample))
    }
}
