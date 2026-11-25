import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

/// A failure to copy one audio sample into a screen-session source ring.
public enum ScreenAudioBridgeError: Error, Equatable, Sendable {
    /// The callback did not contain supported Float32 linear PCM.
    case invalidSample
    /// The owned PCM block did not match the screen session's fixed grid.
    case invalidBlock
    /// The configured role does not have a source ring.
    case unavailableRole
}

/// Copies screen-session audio directly into the existing bounded source rings.
///
/// The ScreenCaptureKit callback borrows its sample storage only for the duration
/// of `appendSystem(sampleBuffer:)`; that method copies directly into the ring and
/// never creates an owned `AudioPCMBlock`.
public final class ScreenAudioBridge: @unchecked Sendable {
    private static let maximumBuffers = 8

    private let lock = NSLock()
    private let systemRing: AudioSourceRingBuffer
    private let microphoneRing: AudioSourceRingBuffer?
    private let hostTicksPerSecond: UInt64
    private let rawBufferList: UnsafeMutableRawPointer
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private var planarPointers: [UnsafeBufferPointer<Float>]
    private var timestampMapper: AudioSourceTimestampMapper?

    /// Creates a direct-copy bridge for screen-session audio sources.
    public init(
        systemRing: AudioSourceRingBuffer,
        microphoneRing: AudioSourceRingBuffer?,
        hostTicksPerSecond: UInt64
    ) {
        self.systemRing = systemRing
        self.microphoneRing = microphoneRing
        self.hostTicksPerSecond = max(1, hostTicksPerSecond)
        let byteCount =
            MemoryLayout<AudioBufferList>.size
            + (Self.maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
        rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawBufferList.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        bufferList = UnsafeMutableAudioBufferListPointer(
            rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        planarPointers = Array(
            repeating: UnsafeBufferPointer(start: nil, count: 0),
            count: Self.maximumBuffers
        )
    }

    deinit {
        rawBufferList.deallocate()
    }

    /// Copies a ScreenCaptureKit system-audio sample directly into the system ring.
    public func appendSystem(sampleBuffer: CMSampleBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
            CMSampleBufferIsValid(sampleBuffer),
            CMSampleBufferDataIsReady(sampleBuffer),
            let info = Self.streamInfo(sampleBuffer),
            loadBufferList(sampleBuffer, bufferCount: info.bufferCount),
            let result = write(
                frameCount: frameCount,
                hostTime: hostTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            )
        else {
            throw ScreenAudioBridgeError.invalidSample
        }
        if result.reason == .invalidFormat || result.reason == .invalidTimestamp {
            throw ScreenAudioBridgeError.invalidSample
        }
    }

    /// Copies an owned system block into the source ring; intended for consumers and tests.
    public func appendSystem(_ block: AudioPCMBlock) throws {
        try append(block, role: .system, ring: systemRing)
    }

    /// Copies an owned microphone block into the optional microphone source ring.
    public func appendMicrophone(_ block: AudioPCMBlock) throws {
        guard let microphoneRing else { throw ScreenAudioBridgeError.unavailableRole }
        try append(block, role: .microphone, ring: microphoneRing)
    }

    private func append(_ block: AudioPCMBlock, role: RecordingTrackRole, ring: AudioSourceRingBuffer) throws {
        guard block.role == role,
            block.sampleRate == 48_000,
            block.frameCount > 0,
            block.range.sampleCount == Int64(block.frameCount),
            block.channelCount == block.channels.count,
            block.channels.allSatisfy({ $0.count == block.frameCount })
        else { throw ScreenAudioBridgeError.invalidBlock }

        let result = withPointers(block.channels, at: 0, collected: []) { pointers in
            ring.write(planar: pointers, frameCount: block.frameCount, hostTime: block.hostTime)
        }
        if result.reason == .invalidFormat || result.reason == .invalidTimestamp {
            throw ScreenAudioBridgeError.invalidBlock
        }
    }

    private func withPointers<T>(
        _ channels: [[Float]],
        at index: Int,
        collected: [UnsafeBufferPointer<Float>],
        body: ([UnsafeBufferPointer<Float>]) -> T
    ) -> T {
        guard index < channels.count else { return body(collected) }
        return channels[index].withUnsafeBufferPointer { pointer in
            withPointers(channels, at: index + 1, collected: collected + [pointer], body: body)
        }
    }

    private func hostTime(for presentationTime: CMTime) -> UInt64 {
        let now = AudioSourceTimestampMapper.hostTicks(
            fromMachTicks: AudioGetCurrentHostTime(),
            machTicksPerSecond: AudioSourceTimestampMapper.nativeHostTicksPerSecond(),
            hostTicksPerSecond: hostTicksPerSecond
        )
        if timestampMapper == nil, presentationTime.isValid, presentationTime.isNumeric {
            timestampMapper = AudioSourceTimestampMapper(
                hostTicksPerSecond: hostTicksPerSecond,
                anchorPTS: presentationTime,
                anchorHostTime: now
            )
        }
        return timestampMapper?.hostTime(for: presentationTime) ?? now
    }

    private func loadBufferList(_ sampleBuffer: CMSampleBuffer, bufferCount: Int) -> Bool {
        guard (1...Self.maximumBuffers).contains(bufferCount) else { return false }
        let size =
            MemoryLayout<AudioBufferList>.size
            + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        var needed = 0
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        return status == noErr && needed <= size
    }

    private func write(frameCount: Int, hostTime: UInt64) -> RingWriteResult? {
        guard frameCount > 0 else { return nil }
        let channelCount = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard (1...2).contains(channelCount) else { return nil }
        if bufferList.count == channelCount {
            for channel in 0..<channelCount {
                let buffer = bufferList[channel]
                guard buffer.mNumberChannels == 1,
                    let data = buffer.mData?.assumingMemoryBound(to: Float.self),
                    Int(buffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size
                else { return nil }
                planarPointers[channel] = UnsafeBufferPointer(start: data, count: frameCount)
            }
            return systemRing.write(
                planar: Array(planarPointers.prefix(channelCount)),
                frameCount: frameCount,
                hostTime: hostTime
            )
        }
        guard bufferList.count == 1,
            bufferList[0].mNumberChannels == UInt32(channelCount),
            let data = bufferList[0].mData?.assumingMemoryBound(to: Float.self),
            Int(bufferList[0].mDataByteSize) >= frameCount * channelCount * MemoryLayout<Float>.size
        else { return nil }
        return systemRing.write(
            interleaved: UnsafeBufferPointer(start: data, count: frameCount * channelCount),
            frameCount: frameCount,
            hostTime: hostTime
        )
    }

    private static func streamInfo(_ sampleBuffer: CMSampleBuffer) -> (bufferCount: Int, channelCount: Int)? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            stream.mFormatID == kAudioFormatLinearPCM,
            stream.mSampleRate > 0,
            stream.mFramesPerPacket == 1,
            stream.mBitsPerChannel == 32,
            stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            stream.mFormatFlags & kAudioFormatFlagIsPacked != 0,
            stream.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0,
            stream.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
            stream.mChannelsPerFrame == 1 || stream.mChannelsPerFrame == 2
        else { return nil }
        let channels = Int(stream.mChannelsPerFrame)
        let nonInterleaved = stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if nonInterleaved {
            guard stream.mBytesPerFrame == 4, stream.mBytesPerPacket == 4 else { return nil }
            return (channels, channels)
        }
        let bytesPerFrame = 4 * stream.mChannelsPerFrame
        guard stream.mBytesPerFrame == bytesPerFrame,
            stream.mBytesPerPacket == bytesPerFrame
        else { return nil }
        return (1, channels)
    }
}

/// Adds or removes only the audio output on an already-running ScreenCaptureKit stream.
public final class ScreenAudioOutputReuse: NSObject, SCStreamOutput, @unchecked Sendable {
    private let bridge: ScreenAudioBridge
    private let queue = DispatchQueue(label: "SnapGlass.screen-audio-output", qos: .userInitiated)
    private let lock = NSLock()
    private weak var attachedStream: SCStream?

    /// Creates an output adapter for an existing screen stream.
    public init(bridge: ScreenAudioBridge) {
        self.bridge = bridge
    }

    /// Attaches only `.audio`; this method never starts the shared stream.
    public func attach(to stream: SCStream) throws {
        lock.lock()
        defer { lock.unlock() }
        guard attachedStream == nil else { return }
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        attachedStream = stream
    }

    /// Detaches only `.audio`; this method never stops the shared stream.
    public func detach(from stream: SCStream) {
        lock.lock()
        defer { lock.unlock() }
        guard attachedStream === stream else { return }
        try? stream.removeStreamOutput(self, type: .audio)
        attachedStream = nil
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        try? bridge.appendSystem(sampleBuffer: sampleBuffer)
    }
}
