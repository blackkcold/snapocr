import Foundation

/// One owned block of deinterleaved PCM audio for a recording track role.
///
/// The `channels` arrays own their sample storage. The block never retains a
/// borrowed buffer pointer, so it is safe to pass across concurrency domains.
public struct AudioPCMBlock: Sendable, Equatable {
    /// The logical track role that produced the block.
    public let role: RecordingTrackRole
    /// The block's sample range on the recording's integer grid.
    ///
    /// While audio is still inside a source ``AudioSourceRingBuffer``, the range
    /// start is a frame index at the source sample rate, including any frames
    /// skipped by producer drops. After the Task 6 resampler maps the block onto
    /// the fixed 48 kHz session grid, the range is expressed in 48 kHz session
    /// samples instead. Consumers must interpret the range together with
    /// ``sampleRate`` and the pipeline stage that produced the block.
    public let range: SampleRange
    /// The sample rate of the block's channels in hertz.
    public let sampleRate: Int
    /// Number of channels stored in `channels`.
    public let channelCount: Int
    /// Number of frames stored in each channel.
    public let frameCount: Int
    /// Host timestamp of the block's first frame.
    public let hostTime: UInt64
    /// Deinterleaved samples, one owned array per channel.
    public let channels: [[Float]]
    /// Whether every sample in the block is digital silence.
    public let isSilence: Bool

    /// Creates an owned PCM block.
    ///
    /// - Parameters:
    ///   - role: The logical track role that produced the block.
    ///   - range: The block's sample range on the recording's integer grid.
    ///   - sampleRate: The sample rate of the block's channels in hertz.
    ///   - channelCount: Number of channels stored in `channels`.
    ///   - frameCount: Number of frames stored in each channel.
    ///   - hostTime: Host timestamp of the block's first frame.
    ///   - channels: Deinterleaved samples, one owned array per channel.
    ///   - isSilence: Whether every sample in the block is digital silence.
    public init(
        role: RecordingTrackRole,
        range: SampleRange,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        hostTime: UInt64,
        channels: [[Float]],
        isSilence: Bool
    ) {
        self.role = role
        self.range = range
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.hostTime = hostTime
        self.channels = channels
        self.isSilence = isSilence
    }
}
