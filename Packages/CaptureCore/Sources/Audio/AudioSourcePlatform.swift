import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Platform protocols

/// A system audio stream that may be owned by a standalone audio-only session
/// or shared with an existing screen-capture session as an audio output.
public protocol SystemAudioStreaming: AnyObject, Sendable {
  /// Stable identity of the platform stream.
  var streamID: UUID { get }
  /// Whether the platform stream is currently capturing.
  var isRunning: Bool { get }
  /// Installs the audio sample callback without starting or stopping capture.
  ///
  /// - Parameter handler: Callback invoked on the platform's serial audio queue.
  /// - Throws: ``AudioSourceError/installFailed(_:)`` when installation fails.
  func installAudioOutput(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws
  /// Removes the audio sample callback without stopping the stream.
  func removeAudioOutput() async
}

/// A system stream created and owned by an audio-only standalone source.
public protocol OwnedSystemAudioStreaming: SystemAudioStreaming {
  /// Starts platform capture.
  ///
  /// - Throws: ``AudioSourceError/startFailed(_:)`` when capture cannot start.
  func startCapture() async throws
  /// Stops platform capture.
  func stopCapture() async
}

/// Creates one owned system stream without implicitly starting it.
public protocol SystemAudioStreamFactory: Sendable {
  /// Creates a configured stream.
  ///
  /// - Returns: A stream that has not started capture.
  /// - Throws: ``AudioSourceError`` when the platform stream cannot be created.
  func makeStream() async throws -> any OwnedSystemAudioStreaming
}

/// A microphone engine with one tap per installed format.
public protocol MicrophoneCaptureEngine: AnyObject, Sendable {
  /// The engine's actual current input format, or `nil` when no input exists.
  var currentFormat: AVAudioFormat? { get }
  /// Whether the engine is currently running.
  var isRunning: Bool { get }
  /// Installs the single microphone tap.
  ///
  /// - Parameters:
  ///   - format: Source format requested from the engine.
  ///   - handler: Callback invoked on the engine's audio thread.
  /// - Throws: ``AudioSourceError/installFailed(_:)`` when the tap cannot install.
  func installTap(
    format: AVAudioFormat,
    handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
  ) throws
  /// Removes the installed tap.
  func removeTap()
  /// Starts the engine.
  ///
  /// - Throws: ``AudioSourceError/startFailed(_:)`` when the engine cannot start.
  func start() throws
  /// Stops the engine.
  func stop()
}

/// Registers and unregisters platform device-change listeners.
public protocol AudioDeviceChangeMonitoring: AnyObject, Sendable {
  /// Starts monitoring and registers the callback.
  ///
  /// - Parameter handler: Callback invoked on a platform monitoring queue.
  /// - Throws: ``AudioSourceError/installFailed(_:)`` when registration fails.
  func start(_ handler: @escaping @Sendable (AudioDeviceChangeEvent) -> Void) throws
  /// Unregisters every listener and clears the callback.
  func stop()
}

// MARK: - Diagnostics

/// Coarse source health derived from callback counters.
public enum AudioSourceHealth: String, Sendable, Equatable {
  /// No callback has been observed.
  case unknown
  /// Every callback since the source started was accepted.
  case healthy
  /// At least one callback dropped frames.
  case degraded
}

/// A control-side diagnostics snapshot.
///
/// Fields are read independently and are not one instantaneous state. After a
/// source is drained, its accepted and dropped counts are conserved.
public struct AudioSourceDiagnosticsSnapshot: Sendable, Equatable {
  /// Callback invocations recorded.
  public let callbackCount: Int64
  /// Frames accepted by the ring.
  public let acceptedFrames: Int64
  /// Frames rejected by the ring or callback.
  public let droppedFrames: Int64
  /// Frames reported as timeline gaps by the ring.
  public let gapFrames: Int64
  /// Coarse health derived from the counters.
  public let health: AudioSourceHealth
  /// Most recent drop reason, if any.
  public let lastDropReason: RingDropReason?
  /// Sixteen fixed callback-duration buckets; the last bucket is overflow.
  public let durationBucketCounts: [Int64]
  /// Always `nil`: a synthetic test cannot claim a real callback p99.
  public let p99CallbackDurationNanos: Int64?

  /// Creates a diagnostics snapshot.
  ///
  /// - Parameters:
  ///   - callbackCount: Callback invocations.
  ///   - acceptedFrames: Accepted frames.
  ///   - droppedFrames: Dropped frames.
  ///   - gapFrames: Timeline gap frames.
  ///   - health: Derived health.
  ///   - lastDropReason: Most recent drop reason.
  ///   - durationBucketCounts: Sixteen duration bucket counts.
  ///   - p99CallbackDurationNanos: Unavailable p99, always `nil`.
  public init(
    callbackCount: Int64,
    acceptedFrames: Int64,
    droppedFrames: Int64,
    gapFrames: Int64,
    health: AudioSourceHealth,
    lastDropReason: RingDropReason?,
    durationBucketCounts: [Int64],
    p99CallbackDurationNanos: Int64?
  ) {
    self.callbackCount = callbackCount
    self.acceptedFrames = acceptedFrames
    self.droppedFrames = droppedFrames
    self.gapFrames = gapFrames
    self.health = health
    self.lastDropReason = lastDropReason
    self.durationBucketCounts = durationBucketCounts
    self.p99CallbackDurationNanos = p99CallbackDurationNanos
  }
}

/// Fixed-size, callback-safe source diagnostics.
///
/// Every callback-side operation is a bounded atomic load or add. There is no
/// allocation, logging, I/O, or lock. One producer owns the instance, so the
/// last-writer fields describe that producer's most recent callback.
public final class AudioSourceDiagnostics: @unchecked Sendable {
  /// Upper bounds in nanoseconds for the first fifteen buckets.
  public static let durationBucketUpperBoundsNanos: [Int64] = [
    50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000, 4_000_000,
    8_000_000, 16_000_000, 32_000_000, 64_000_000, 128_000_000,
    256_000_000, 512_000_000, 1_000_000_000,
  ]

  private let callbackCounter: any AudioAtomicCounter
  private let acceptedCounter: any AudioAtomicCounter
  private let droppedCounter: any AudioAtomicCounter
  private let gapCounter: any AudioAtomicCounter
  private let lastDropCode: any AudioAtomicCounter
  private let reasonPublicationLock = NSLock()
  private let bucketCounters: [any AudioAtomicCounter]

  /// Creates an empty diagnostics recorder.
  public init() {
    callbackCounter = AudioAtomicCounterFactory.make(mode: .automatic)
    acceptedCounter = AudioAtomicCounterFactory.make(mode: .automatic)
    droppedCounter = AudioAtomicCounterFactory.make(mode: .automatic)
    gapCounter = AudioAtomicCounterFactory.make(mode: .automatic)
    lastDropCode = AudioAtomicCounterFactory.make(mode: .automatic)
    bucketCounters = (0..<16).map { _ in AudioAtomicCounterFactory.make(mode: .automatic) }
  }

  /// Records one callback without allocating or blocking.
  ///
  /// `lastDropReason` publication uses a finite try-gate; under concurrent
  /// producers it remains the previous coherent value while all counters and
  /// rejected-frame totals stay observable.
  ///
  /// - Parameters:
  ///   - durationNanos: Callback duration in nanoseconds.
  ///   - acceptedFrames: Frames accepted by the ring.
  ///   - droppedFrames: Frames dropped by the callback or ring.
  ///   - gapFrames: Timeline gap frames reported by the ring.
  ///   - dropReason: Most recent drop reason, or `nil`.
  public func recordCallback(
    durationNanos: Int64,
    acceptedFrames: Int,
    droppedFrames: Int,
    gapFrames: Int,
    dropReason: RingDropReason?
  ) {
    callbackCounter.fetchAddRelease(1)
    acceptedCounter.fetchAddRelease(Int64(acceptedFrames))
    droppedCounter.fetchAddRelease(Int64(droppedFrames))
    gapCounter.fetchAddRelease(Int64(gapFrames))
    let bucket = Self.bucketIndex(for: durationNanos)
    bucketCounters[bucket].fetchAddRelease(1)
    if let dropReason, reasonPublicationLock.try() {
      let code = Self.code(for: dropReason)
      lastDropCode.fetchAddRelease(code - lastDropCode.loadAcquire())
      reasonPublicationLock.unlock()
    }
  }

  /// Returns a control-side snapshot; reading never mutates callback state.
  ///
  /// - Returns: A non-instantaneous counter snapshot.
  public func snapshot() -> AudioSourceDiagnosticsSnapshot {
    let callbacks = callbackCounter.loadAcquire()
    let dropped = droppedCounter.loadAcquire()
    let health: AudioSourceHealth
    if callbacks == 0 {
      health = .unknown
    } else if dropped > 0 {
      health = .degraded
    } else {
      health = .healthy
    }
    let buckets = bucketCounters.map { $0.loadAcquire() }
    return AudioSourceDiagnosticsSnapshot(
      callbackCount: callbacks,
      acceptedFrames: acceptedCounter.loadAcquire(),
      droppedFrames: dropped,
      gapFrames: gapCounter.loadAcquire(),
      health: health,
      lastDropReason: Self.reason(for: lastDropCode.loadAcquire()),
      durationBucketCounts: buckets,
      p99CallbackDurationNanos: nil
    )
  }

  private static func bucketIndex(for durationNanos: Int64) -> Int {
    let clamped = max(0, durationNanos)
    for index in durationBucketUpperBoundsNanos.indices
    where clamped <= durationBucketUpperBoundsNanos[index] {
      return index
    }
    return 15
  }

  private static func code(for reason: RingDropReason) -> Int64 {
    switch reason {
    case .overflow: 1
    case .closed: 2
    case .reentrantProducer: 3
    case .reentrantConsumer: 4
    case .invalidFormat: 5
    case .invalidTimestamp: 6
    }
  }

  private static func reason(for code: Int64) -> RingDropReason? {
    switch code {
    case 1: .overflow
    case 2: .closed
    case 3: .reentrantProducer
    case 4: .reentrantConsumer
    case 5: .invalidFormat
    case 6: .invalidTimestamp
    default: nil
    }
  }
}

// MARK: - ScreenCaptureKit defaults

/// Creates ScreenCaptureKit streams configured for audio-only capture.
public struct SCKSystemAudioStreamFactory: SystemAudioStreamFactory {
  /// Creates a factory without touching screen-capture hardware.
  public init() {}

  /// Returns the 2x2 low-frame-rate audio-only stream configuration.
  ///
  /// - Returns: A fresh configuration with audio capture enabled and the
  ///   current process excluded.
  public static func makeConfiguration() -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.showsCursor = false
    return configuration
  }

  /// Creates one configured stream without starting it.
  ///
  /// - Returns: An owned ScreenCaptureKit stream.
  /// - Throws: ``AudioSourceError/unavailable(_:)`` when no display can back the filter.
  public func makeStream() async throws -> any OwnedSystemAudioStreaming {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    guard let display = content.displays.first else {
      throw AudioSourceError.unavailable("no display available for audio stream")
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    return SCKSystemAudioStream(
      filter: filter,
      configuration: Self.makeConfiguration()
    )
  }
}

private final class SCKStreamDelegateProxy: NSObject, SCStreamDelegate, @unchecked Sendable {
  weak var owner: SCKSystemAudioStream?

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    owner?.platformStreamStopped()
  }
}

/// A ScreenCaptureKit stream wrapper with an installable audio output.
///
/// Audio callbacks run on one serial queue. Control methods lock only their own
/// small state; `@unchecked Sendable` is backed by that queue and lock.
public final class SCKSystemAudioStream: NSObject, OwnedSystemAudioStreaming, SCStreamOutput,
  SCStreamDelegate, @unchecked Sendable {
  /// Stable wrapper identity.
  public let streamID = UUID()
  private let stream: SCStream
  private let streamDelegate: SCKStreamDelegateProxy
  private let callbackQueue: DispatchQueue
  private let lock = NSLock()
  private var handler: (@Sendable (CMSampleBuffer) -> Void)?
  private var running = false

  /// Creates a stream around a filter and configuration without starting it.
  ///
  /// - Parameters:
  ///   - filter: ScreenCaptureKit content filter.
  ///   - configuration: Audio-only stream configuration.
  public init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
    callbackQueue = DispatchQueue(label: "com.snapglass.system-audio.callback")
    let delegate = SCKStreamDelegateProxy()
    stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
    streamDelegate = delegate
    super.init()
    delegate.owner = self
  }

  /// Whether capture has been started and not stopped.
  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  /// Installs the audio callback on a dedicated serial queue.
  ///
  /// - Parameter handler: Audio sample callback.
  /// - Throws: ``AudioSourceError/installFailed(_:)`` when the stream rejects it.
  public func installAudioOutput(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
    lock.lock()
    self.handler = handler
    lock.unlock()
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
    } catch {
      lock.lock()
      self.handler = nil
      lock.unlock()
      throw AudioSourceError.installFailed("SCStream audio output: \(error)")
    }
  }

  /// Removes the audio callback without stopping the stream.
  public func removeAudioOutput() async {
    try? stream.removeStreamOutput(self, type: .audio)
    clearHandler()
  }

  /// Starts ScreenCaptureKit capture.
  ///
  /// - Throws: ``AudioSourceError/startFailed(_:)`` when the stream cannot start.
  public func startCapture() async throws {
    guard !isRunning else { return }
    do {
      try await stream.startCapture()
    } catch {
      throw AudioSourceError.startFailed("SCStream start: \(error)")
    }
    setRunning(true)
  }

  /// Stops ScreenCaptureKit capture.
  public func stopCapture() async {
    guard isRunning else { return }
    try? await stream.stopCapture()
    setRunning(false)
  }

  private func clearHandler() {
    lock.lock()
    handler = nil
    lock.unlock()
  }

  private func setRunning(_ value: Bool) {
    lock.lock()
    running = value
    lock.unlock()
  }

  fileprivate func platformStreamStopped() {
    lock.lock()
    running = false
    handler = nil
    lock.unlock()
  }

  /// Forwards audio sample buffers to the installed handler.
  ///
  /// - Parameters:
  ///   - stream: Source stream.
  ///   - sampleBuffer: Borrowed audio sample buffer.
  ///   - type: Output type.
  public func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio else { return }
    lock.lock()
    let callback = handler
    lock.unlock()
    callback?(sampleBuffer)
  }
}

// MARK: - AVAudioEngine default

final class AudioSystemCallbackBox: @unchecked Sendable {
  let generation: AudioSourceGeneration
  let gate: AudioCallbackGate
  private let hostTicksPerSecond: UInt64
  private let diagnostics: AudioSourceDiagnostics?
  private let hostClock: @Sendable () -> UInt64
  private var timestampMapper: AudioSourceTimestampMapper?
  private let rawBufferList: UnsafeMutableRawPointer
  private let bufferList: UnsafeMutableAudioBufferListPointer
  private var planarPointers: [UnsafeBufferPointer<Float>]
  private let maximumBuffers = 8

  init(
    generation: AudioSourceGeneration,
    hostTicksPerSecond: UInt64,
    diagnostics: AudioSourceDiagnostics?,
    timestampMapper: AudioSourceTimestampMapper?,
    hostClock: @escaping @Sendable () -> UInt64,
    gate: AudioCallbackGate
  ) {
    self.generation = generation
    self.hostTicksPerSecond = hostTicksPerSecond
    self.diagnostics = diagnostics
    self.timestampMapper = timestampMapper
    self.hostClock = hostClock
    self.gate = gate
    let byteCount = MemoryLayout<AudioBufferList>.size
      + (maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
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
      count: generation.format.channelCount
    )
  }

  deinit {
    rawBufferList.deallocate()
  }

  func handle(_ sampleBuffer: CMSampleBuffer) {
    let started = diagnostics == nil ? 0 : DispatchTime.now().uptimeNanoseconds
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    var accepted = 0
    var dropped = 0
    var gap = 0
    var reason: RingDropReason?
    let gapBefore = generation.ringBuffer.stats.gapFrames

    if frameCount > 0, let info = Self.streamInfo(sampleBuffer),
      info.format.sampleRate == generation.format.sampleRate,
      info.format.channelCount == generation.format.channelCount,
      loadBufferList(sampleBuffer, bufferCount: info.bufferCount) {
      let hostTime = hostTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
      if let result = write(frameCount: frameCount, hostTime: hostTime) {
        accepted = result.acceptedFrames
        dropped = result.droppedFrames
        reason = result.reason
      } else {
        dropped = frameCount
        reason = .invalidFormat
      }
    } else if frameCount > 0 {
      dropped = frameCount
      reason = .invalidFormat
    }
    let gapAfter = generation.ringBuffer.stats.gapFrames
    gap = max(0, Int(gapAfter - gapBefore))

    guard let diagnostics else { return }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    diagnostics.recordCallback(
      durationNanos: Int64(min(elapsed, UInt64(Int64.max))),
      acceptedFrames: accepted,
      droppedFrames: dropped,
      gapFrames: gap,
      dropReason: reason
    )
  }

  private func hostTime(for pts: CMTime) -> UInt64 {
    if timestampMapper == nil, pts.isValid {
      timestampMapper = AudioSourceTimestampMapper(
        hostTicksPerSecond: hostTicksPerSecond,
        anchorPTS: pts,
        anchorHostTime: hostClock()
      )
    }
    if let mapped = timestampMapper?.hostTime(for: pts) {
      return mapped
    }
    return hostClock()
  }

  private func loadBufferList(_ sampleBuffer: CMSampleBuffer, bufferCount: Int) -> Bool {
    guard bufferCount >= 1, bufferCount <= maximumBuffers else { return false }
    var needed = 0
    var blockBuffer: CMBlockBuffer?
    let size = MemoryLayout<AudioBufferList>.size
      + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &needed,
      bufferListOut: bufferList.unsafeMutablePointer,
      bufferListSize: size,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    if status == noErr, needed <= size {
      return true
    }
    let maximumSize = MemoryLayout<AudioBufferList>.size
      + (maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
    guard needed > 0, needed <= maximumSize else { return false }
    var retryBlock: CMBlockBuffer?
    let retryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: bufferList.unsafeMutablePointer,
      bufferListSize: needed,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      blockBufferOut: &retryBlock
    )
    return retryStatus == noErr
  }

  private func write(frameCount: Int, hostTime: UInt64) -> RingWriteResult? {
    let channelCount = generation.format.channelCount
    let buffers = bufferList.count
    if buffers == channelCount {
      for channel in 0..<channelCount {
        let buffer = bufferList[channel]
        guard buffer.mNumberChannels == 1,
          let data = buffer.mData?.assumingMemoryBound(to: Float.self),
          Int(buffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size
        else {
          return nil
        }
        planarPointers[channel] = UnsafeBufferPointer(start: data, count: frameCount)
      }
      return generation.ringBuffer.write(
        planar: planarPointers,
        frameCount: frameCount,
        hostTime: hostTime
      )
    }
    if buffers == 1, bufferList[0].mNumberChannels == UInt32(channelCount),
      let data = bufferList[0].mData?.assumingMemoryBound(to: Float.self),
      Int(bufferList[0].mDataByteSize) >= frameCount * channelCount * MemoryLayout<Float>.size {
      let samples = UnsafeBufferPointer(start: data, count: frameCount * channelCount)
      return generation.ringBuffer.write(
        interleaved: samples,
        frameCount: frameCount,
        hostTime: hostTime
      )
    }
    return nil
  }

  private static func streamInfo(
    _ sampleBuffer: CMSampleBuffer
  ) -> (format: AudioSourceFormat, bufferCount: Int)? {
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
    else {
      return nil
    }
    let format = AudioSourceFormat(
      sampleRate: Int(stream.mSampleRate.rounded()),
      channelCount: Int(stream.mChannelsPerFrame)
    )
    let nonInterleaved = stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    if nonInterleaved {
      guard stream.mBytesPerFrame == 4, stream.mBytesPerPacket == 4 else {
        return nil
      }
      return (format, Int(stream.mChannelsPerFrame))
    }
    let expectedBytesPerFrame = 4 * stream.mChannelsPerFrame
    guard stream.mBytesPerFrame == expectedBytesPerFrame,
      stream.mBytesPerPacket == expectedBytesPerFrame
    else {
      return nil
    }
    return (format, 1)
  }
}
