import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// A failure while allocating or converting an audio buffer.
public enum AudioBufferFactoryError: Error, Equatable {
    /// The requested PCM buffer could not be allocated.
    case allocationFailed
    /// The channel layout, sample rate, or time information was invalid.
    case invalidFormat
}

/// Creates owned PCM buffers and Core Media sample buffers from planar samples.
public enum AudioSampleBufferFactory {
    /// Creates a deinterleaved Float32 PCM buffer.
    ///
    /// - Parameters:
    ///   - channels: One non-empty sample array per channel.
    ///   - sampleRate: Sample rate in hertz.
    /// - Returns: A buffer that owns its sample storage.
    /// - Throws: ``AudioBufferFactoryError/invalidFormat`` for an invalid layout
    ///   or ``AudioBufferFactoryError/allocationFailed`` when allocation fails.
    public static func makePCMBuffer(
        channels: [[Float]],
        sampleRate: Int
    ) throws -> AVAudioPCMBuffer {
        guard sampleRate > 0, sampleRate <= Int(Int32.max) else {
            throw AudioBufferFactoryError.invalidFormat
        }
        guard !channels.isEmpty, channels.count <= 64 else {
            throw AudioBufferFactoryError.invalidFormat
        }
        guard let frameCount = channels.first?.count, frameCount > 0 else {
            throw AudioBufferFactoryError.invalidFormat
        }
        guard frameCount <= Int(UInt32.max) else {
            throw AudioBufferFactoryError.invalidFormat
        }
        guard channels.allSatisfy({ $0.count == frameCount }) else {
            throw AudioBufferFactoryError.invalidFormat
        }
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channels.count)
            )
        else {
            throw AudioBufferFactoryError.invalidFormat
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else {
            throw AudioBufferFactoryError.allocationFailed
        }
        guard let data = buffer.floatChannelData else {
            throw AudioBufferFactoryError.invalidFormat
        }
        for channel in 0..<channels.count {
            let source = channels[channel]
            for frame in 0..<frameCount {
                data[channel][frame] = source[frame]
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }

    /// Creates a Core Media sample buffer from an existing Float32 PCM buffer.
    ///
    /// The samples are copied into an interleaved packet so the sample buffer
    /// owns independent storage. The presentation time is carried unchanged.
    ///
    /// - Parameters:
    ///   - buffer: Planar (non-interleaved) Float32 channel data. Interleaved
    ///     buffers fail closed with ``AudioBufferFactoryError/invalidFormat``.
    ///   - presentationTime: Presentation timestamp of the first frame.
    /// - Returns: A ready sample buffer with matching timing and format.
    /// - Throws: ``AudioBufferFactoryError`` for invalid input or allocation
    ///   failure.
    public static func makeSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        let prepared = try prepareSampleBuffer(
            from: buffer,
            presentationTime: presentationTime
        )
        let block = try makeBlockBuffer(samples: prepared.interleaved)
        var timing = prepared.timing
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: prepared.formatDescription,
            sampleCount: prepared.frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let result = sampleBuffer else {
            throw AudioBufferFactoryError.allocationFailed
        }
        return result
    }

    private struct PreparedSampleBuffer {
        let interleaved: [Float]
        let frameCount: Int
        let formatDescription: CMAudioFormatDescription
        let timing: CMSampleTimingInfo
    }

    private static func prepareSampleBuffer(
        from buffer: AVAudioPCMBuffer,
        presentationTime: CMTime
    ) throws -> PreparedSampleBuffer {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let rawSampleRate = buffer.format.sampleRate
        guard frameCount > 0,
            channelCount > 0,
            channelCount <= 64,
            presentationTime.isValid,
            buffer.format.isInterleaved == false,
            rawSampleRate.isFinite,
            rawSampleRate > 0,
            rawSampleRate <= Double(Int32.max)
        else {
            throw AudioBufferFactoryError.invalidFormat
        }
        guard let channelData = buffer.floatChannelData else {
            throw AudioBufferFactoryError.invalidFormat
        }
        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                interleaved[frame * channelCount + channel] = channelData[channel][frame]
            }
        }
        let sampleRate = Int(rawSampleRate)
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        let description = try makeFormatDescription(
            sampleRate: buffer.format.sampleRate,
            channelCount: channelCount
        )
        return PreparedSampleBuffer(
            interleaved: interleaved,
            frameCount: frameCount,
            formatDescription: description,
            timing: timing
        )
    }

    private static func makeBlockBuffer(samples: [Float]) throws -> CMBlockBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.size
        guard byteCount > 0, byteCount <= Int(UInt32.max) else {
            throw AudioBufferFactoryError.invalidFormat
        }
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let block = blockBuffer else {
            throw AudioBufferFactoryError.allocationFailed
        }
        let replaceStatus: OSStatus? = samples.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return nil
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard let replaceStatus, replaceStatus == noErr else {
            throw AudioBufferFactoryError.allocationFailed
        }
        return block
    }

    private static func makeFormatDescription(
        sampleRate: Double,
        channelCount: Int
    ) throws -> CMAudioFormatDescription {
        let bytesPerFrame = MemoryLayout<Float>.size * channelCount
        guard bytesPerFrame > 0, bytesPerFrame <= Int(UInt32.max) else {
            throw AudioBufferFactoryError.invalidFormat
        }
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let description = formatDescription else {
            throw AudioBufferFactoryError.allocationFailed
        }
        return description
    }
}
