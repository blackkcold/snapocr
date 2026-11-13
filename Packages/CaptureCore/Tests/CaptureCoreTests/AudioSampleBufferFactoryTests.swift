import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

struct AudioSampleBufferFactoryTests {
    @Test func makePCMBufferOwnsDeinterleavedFloatData() throws {
        let channels: [[Float]] = [
            [0, 0.25, -0.5, 1],
            [0.125, -0.125, 0.75, -1],
        ]
        let buffer = try AudioSampleBufferFactory.makePCMBuffer(
            channels: channels,
            sampleRate: 48_000
        )

        #expect(buffer.frameLength == 4)
        #expect(buffer.frameCapacity >= 4)
        #expect(buffer.format.sampleRate == 48_000)
        #expect(buffer.format.channelCount == 2)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)

        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<4 {
                #expect(data[channel][frame] == channels[channel][frame])
            }
        }
    }

    @Test func makePCMBufferRejectsInvalidFormats() {
        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makePCMBuffer(channels: [], sampleRate: 48_000)
        }
        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makePCMBuffer(
                channels: [[0, 1], [0]],
                sampleRate: 48_000
            )
        }
        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makePCMBuffer(
                channels: [[0, 1]],
                sampleRate: 0
            )
        }
        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makePCMBuffer(
                channels: [[], []],
                sampleRate: 48_000
            )
        }
        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makePCMBuffer(
                channels: [[0, 1], [0, 1], [0, 1]],
                sampleRate: 48_000
            )
        }
    }

    @Test func makeSampleBufferCarriesTimingAndFormat() throws {
        let pcm = try AudioSampleBufferFactory.makePCMBuffer(
            channels: [[0, 0.5, -0.5, 1], [0.25, 0.25, -0.25, -0.25]],
            sampleRate: 48_000
        )
        let presentationTime = CMTime(value: 123_456, timescale: 48_000)

        let sampleBuffer = try AudioSampleBufferFactory.makeSampleBuffer(
            from: pcm,
            presentationTime: presentationTime
        )

        #expect(CMSampleBufferGetNumSamples(sampleBuffer) == 4)
        #expect(CMSampleBufferGetPresentationTimeStamp(sampleBuffer) == presentationTime)
        #expect(CMSampleBufferIsValid(sampleBuffer))

        let description = try #require(CMSampleBufferGetFormatDescription(sampleBuffer))
        let streamDescription = try #require(
            CMAudioFormatDescriptionGetStreamBasicDescription(description)
        )
        #expect(streamDescription.pointee.mSampleRate == 48_000)
        #expect(streamDescription.pointee.mChannelsPerFrame == 2)
        #expect(streamDescription.pointee.mBitsPerChannel == 32)
        #expect(streamDescription.pointee.mBytesPerFrame == 8)
        #expect(streamDescription.pointee.mBytesPerPacket == 8)
        #expect(streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0)

        let block = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
        #expect(CMBlockBufferGetDataLength(block) == 32)
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        #expect(pointerStatus == noErr)
        #expect(lengthAtOffset == 32)
        #expect(totalLength == 32)
        let floats = try #require(dataPointer).withMemoryRebound(to: Float.self, capacity: 8) {
            Array(UnsafeBufferPointer(start: $0, count: 8))
        }
        #expect(floats == [0, 0.25, 0.5, 0.25, -0.5, -0.25, 1, -0.25])

        var timing = CMSampleTimingInfo()
        let status = CMSampleBufferGetSampleTimingInfo(
            sampleBuffer,
            at: 0,
            timingInfoOut: &timing
        )
        #expect(status == noErr)
        #expect(timing.presentationTimeStamp == presentationTime)
        #expect(timing.duration.value == 1)
        #expect(timing.duration.timescale == 48_000)
    }

    @Test func makeSampleBufferRejectsInvalidPresentationTime() throws {
        let pcm = try AudioSampleBufferFactory.makePCMBuffer(
            channels: [[0, 1]],
            sampleRate: 48_000
        )

        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makeSampleBuffer(
                from: pcm,
                presentationTime: .invalid
            )
        }
    }

    @Test func makeSampleBufferRejectsInterleavedInput() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: true
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        let rawData = try #require(audioBuffer.mData)
        let samples = rawData.assumingMemoryBound(to: Float.self)
        samples[0] = 0.1
        samples[1] = 0.9
        samples[2] = 0.2
        samples[3] = 0.8

        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makeSampleBuffer(
                from: buffer,
                presentationTime: CMTime(value: 0, timescale: 48_000)
            )
        }
    }

    @Test func makeSampleBufferRejectsHugeFiniteRateWithoutTrapping() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 1e19, channels: 1)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        if let data = buffer.floatChannelData {
            data[0][0] = 0.25
        }

        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makeSampleBuffer(
                from: buffer,
                presentationTime: CMTime(value: 0, timescale: 48_000)
            )
        }
    }

    @Test func makeSampleBufferRejectsZeroFrames() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 0

        #expect(throws: AudioBufferFactoryError.invalidFormat) {
            _ = try AudioSampleBufferFactory.makeSampleBuffer(
                from: buffer,
                presentationTime: CMTime(value: 0, timescale: 48_000)
            )
        }
    }

    @Test func makeSampleBufferOwnsDataAfterSourceBufferIsReleased() throws {
        weak var weakSource: AVAudioPCMBuffer?
        func makeOwnedSampleBuffer() throws -> CMSampleBuffer {
            try autoreleasepool {
                let source = try AudioSampleBufferFactory.makePCMBuffer(
                    channels: [[0.1, 0.2], [0.9, 0.8]],
                    sampleRate: 48_000
                )
                weakSource = source
                return try AudioSampleBufferFactory.makeSampleBuffer(
                    from: source,
                    presentationTime: CMTime(value: 0, timescale: 48_000)
                )
            }
        }

        let sampleBuffer = try makeOwnedSampleBuffer()
        #expect(weakSource == nil)

        let block = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        var total = 0
        let status = CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &total,
            dataPointerOut: &pointer
        )
        #expect(status == noErr)
        let floats = try #require(pointer).withMemoryRebound(to: Float.self, capacity: 4) {
            Array(UnsafeBufferPointer(start: $0, count: 4))
        }
        #expect(floats == [0.1, 0.9, 0.2, 0.8])
    }

    @Test func makeSampleBufferAcceptsMonophonicPCM() throws {
        let pcm = try AudioSampleBufferFactory.makePCMBuffer(
            channels: [[0, 0.5, -0.5]],
            sampleRate: 44_100
        )
        let sampleBuffer = try AudioSampleBufferFactory.makeSampleBuffer(
            from: pcm,
            presentationTime: CMTime(value: 7, timescale: 44_100)
        )

        #expect(CMSampleBufferGetNumSamples(sampleBuffer) == 3)
        let description = try #require(CMSampleBufferGetFormatDescription(sampleBuffer))
        let streamDescription = try #require(
            CMAudioFormatDescriptionGetStreamBasicDescription(description)
        )
        #expect(streamDescription.pointee.mSampleRate == 44_100)
        #expect(streamDescription.pointee.mChannelsPerFrame == 1)
    }
}
