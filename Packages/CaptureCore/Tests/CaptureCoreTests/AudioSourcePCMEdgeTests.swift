import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

// MARK: - Synthetic PCM builders

func makeRawFormatDescription(stream: AudioStreamBasicDescription) throws -> CMAudioFormatDescription {
  var mutable = stream
  var description: CMAudioFormatDescription?
  let status = CMAudioFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    asbd: &mutable,
    layoutSize: 0,
    layout: nil,
    magicCookieSize: 0,
    magicCookie: nil,
    extensions: nil,
    formatDescriptionOut: &description
  )
  guard status == noErr, let description else {
    throw AudioSourceError.invalidFormat
  }
  return description
}

func makeRawSampleBuffer(
  stream: AudioStreamBasicDescription,
  bytes: [UInt8],
  frameCount: Int,
  presentationTime: CMTime
) throws -> CMSampleBuffer {
  guard frameCount > 0, !bytes.isEmpty, bytes.count <= Int(UInt32.max) else {
    throw AudioSourceError.invalidFormat
  }
  let description = try makeRawFormatDescription(stream: stream)
  var block: CMBlockBuffer?
  let blockStatus = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault,
    memoryBlock: nil,
    blockLength: bytes.count,
    blockAllocator: kCFAllocatorDefault,
    customBlockSource: nil,
    offsetToData: 0,
    dataLength: bytes.count,
    flags: 0,
    blockBufferOut: &block
  )
  guard blockStatus == noErr, let block else {
    throw AudioSourceError.invalidFormat
  }
  let replaceStatus = bytes.withUnsafeBytes { raw in
    guard let base = raw.baseAddress else { return OSStatus(-1) }
    return CMBlockBufferReplaceDataBytes(
      with: base,
      blockBuffer: block,
      offsetIntoDestination: 0,
      dataLength: bytes.count
    )
  }
  guard replaceStatus == noErr else {
    throw AudioSourceError.invalidFormat
  }
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: CMTimeScale(stream.mSampleRate)),
    presentationTimeStamp: presentationTime,
    decodeTimeStamp: .invalid
  )
  var sampleBuffer: CMSampleBuffer?
  let status = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault,
    dataBuffer: block,
    formatDescription: description,
    sampleCount: frameCount,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timing,
    sampleSizeEntryCount: 0,
    sampleSizeArray: nil,
    sampleBufferOut: &sampleBuffer
  )
  guard status == noErr, let sampleBuffer else {
    throw AudioSourceError.invalidFormat
  }
  return sampleBuffer
}

func floatBytes(_ values: [Float]) -> [UInt8] {
  values.withUnsafeBytes { Array($0) }
}

func doubleBytes(_ values: [Double]) -> [UInt8] {
  values.withUnsafeBytes { Array($0) }
}

func makeFloat32Stream(
  sampleRate: Double,
  channels: UInt32,
  interleaved: Bool,
  bytesPerFrame: UInt32
) -> AudioStreamBasicDescription {
  var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
  if !interleaved {
    flags |= kAudioFormatFlagIsNonInterleaved
  }
  return AudioStreamBasicDescription(
    mSampleRate: sampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: flags,
    mBytesPerPacket: bytesPerFrame,
    mFramesPerPacket: 1,
    mBytesPerFrame: bytesPerFrame,
    mChannelsPerFrame: channels,
    mBitsPerChannel: 32,
    mReserved: 0
  )
}

func makeInterleavedPCMBuffer(
  samples: [Float],
  sampleRate: Double,
  channels: AVAudioChannelCount
) throws -> AVAudioPCMBuffer {
  guard
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: channels,
      interleaved: true
    ),
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(samples.count / Int(channels))
    )
  else {
    throw AudioSourceError.invalidFormat
  }
  let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
  guard list.count == 1, let raw = list[0].mData?.assumingMemoryBound(to: Float.self) else {
    throw AudioSourceError.invalidFormat
  }
  for index in samples.indices {
    raw[index] = samples[index]
  }
  buffer.frameLength = AVAudioFrameCount(samples.count / Int(channels))
  return buffer
}

// MARK: - Clock mapping

@Test func timestampMapperAnchorsRelativePTSInTwentyFourMegahertzDomain() {
  let mapper = AudioSourceTimestampMapper(
    hostTicksPerSecond: 24_000_000,
    anchorPTS: CMTime(value: 0, timescale: 48_000),
    anchorHostTime: 24_000_000
  )

  let halfSecond = mapper.hostTime(for: CMTime(value: 24_000, timescale: 48_000))
  let oneSecond = mapper.hostTime(for: CMTime(value: 48_000, timescale: 48_000))

  #expect(halfSecond == 36_000_000)
  #expect(oneSecond == 48_000_000)
}

@Test func timestampMapperRejectsInvalidAndOverflowingTimes() {
  let mapper = AudioSourceTimestampMapper(
    hostTicksPerSecond: 24_000_000,
    anchorPTS: .zero,
    anchorHostTime: 1_000
  )

  #expect(mapper.hostTime(for: .invalid) == nil)
  #expect(mapper.hostTime(for: CMTime(value: Int64.max, timescale: 1)) == nil)
  #expect(mapper.hostTime(for: CMTime(value: -1, timescale: 1)) == nil)
  #expect(mapper.hostTime(for: CMTime(value: -1, timescale: 1_000_000_000)) == nil)
}

@Test func timestampMapperConvertsNativeMachTicksIntoConfiguredDomain() {
  #expect(
    AudioSourceTimestampMapper.hostTicks(
      fromMachTicks: 24_000_000,
      machTicksPerSecond: 24_000_000,
      hostTicksPerSecond: 1_000_000_000
    ) == 1_000_000_000
  )
  #expect(
    AudioSourceTimestampMapper.hostTicks(
      fromMachTicks: 0,
      machTicksPerSecond: 0,
      hostTicksPerSecond: 1_000_000_000
    ) == 0
  )
}

@Test func systemMapperDomainMismatchFailsStart() async throws {
  let mapper = AudioSourceTimestampMapper(
    hostTicksPerSecond: 1_000_000_000,
    anchorPTS: .zero,
    anchorHostTime: 0
  )
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 24_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { FakeSystemStream() }),
    timestampMapper: mapper
  )

  await #expect(throws: AudioSourceError.self) {
    try await source.start()
  }
}

@Test func systemSecondGenerationResetsPTSAnchor() async throws {
  let first = FakeSystemStream()
  let second = FakeSystemStream()
  let streams = [first, second]
  var index = 0
  let factory = FakeSystemAudioStreamFactory(make: {
    let stream = streams[index]
    index += 1
    return stream
  })
  let mapper = AudioSourceTimestampMapper(
    hostTicksPerSecond: 24_000_000,
    anchorPTS: .zero,
    anchorHostTime: 24_000_000
  )
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 24_000_000,
    capacitySeconds: 0.1,
    factory: factory,
    timestampMapper: mapper,
    hostClock: { 30_000_000 }
  )
  try await source.start()
  let firstGeneration = await source.currentGeneration()
  first.emit(
    try makeRawSampleBuffer(
      stream: makeFloat32Stream(sampleRate: 48_000, channels: 2, interleaved: true, bytesPerFrame: 8),
      bytes: floatBytes([1, 11]),
      frameCount: 1,
      presentationTime: CMTime(value: 48_000, timescale: 48_000)
    )
  )
  _ = firstGeneration.ringBuffer.finishProducing()
  let firstBlock = drainSystemRing(firstGeneration.ringBuffer).first
  #expect(firstBlock?.hostTime == 48_000_000)

  let preparation = await source.prepareReconfiguration(
    AudioDeviceChangeEvent(
      role: .system,
      deviceID: "opaque-output",
      format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
  )
  guard case .prepared(let secondGeneration) = preparation else {
    Issue.record("expected second generation")
    return
  }
  #expect(await source.commitReconfiguration(secondGeneration))
  second.emit(
    try makeRawSampleBuffer(
      stream: makeFloat32Stream(sampleRate: 48_000, channels: 2, interleaved: true, bytesPerFrame: 8),
      bytes: floatBytes([1, 11]),
      frameCount: 1,
      presentationTime: .zero
    )
  )
  _ = secondGeneration.ringBuffer.finishProducing()
  let secondBlock = drainSystemRing(secondGeneration.ringBuffer).first
  #expect(secondBlock?.hostTime == 30_000_000)
}

@Test func systemRelativePTSMapsIntoConfiguredHostDomain() async throws {
  let mapper = AudioSourceTimestampMapper(
    hostTicksPerSecond: 24_000_000,
    anchorPTS: CMTime(value: 0, timescale: 48_000),
    anchorHostTime: 24_000_000
  )
  let stream = FakeSystemStream()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 24_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    timestampMapper: mapper
  )
  try await source.start()
  let generation = await source.currentGeneration()
  let sample = try makeRawSampleBuffer(
    stream: makeFloat32Stream(sampleRate: 48_000, channels: 2, interleaved: true, bytesPerFrame: 8),
    bytes: floatBytes([1, 11, 2, 12]),
    frameCount: 2,
    presentationTime: CMTime(value: 24_000, timescale: 48_000)
  )

  stream.emit(sample)
  _ = generation.ringBuffer.finishProducing()
  let blocks = drainSystemRing(generation.ringBuffer)

  #expect(blocks.first?.hostTime == 36_000_000)
}

@Test func systemInvalidPTSFallsBackToInjectedHostClock() async throws {
  let stream = FakeSystemStream()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 24_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    hostClock: { 77_000 }
  )
  try await source.start()
  let generation = await source.currentGeneration()
  let sample = try makeRawSampleBuffer(
    stream: makeFloat32Stream(sampleRate: 48_000, channels: 2, interleaved: true, bytesPerFrame: 8),
    bytes: floatBytes([1, 11]),
    frameCount: 1,
    presentationTime: .invalid
  )

  stream.emit(sample)
  _ = generation.ringBuffer.finishProducing()
  let blocks = drainSystemRing(generation.ringBuffer)

  #expect(blocks.first?.hostTime == 77_000)
}

// MARK: - Layout validation

@Test func systemPlanarStereoPreservesAsymmetricChannels() async throws {
  let stream = FakeSystemStream()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream })
  )
  try await source.start()
  let generation = await source.currentGeneration()
  let sample = try makeRawSampleBuffer(
    stream: makeFloat32Stream(sampleRate: 48_000, channels: 2, interleaved: false, bytesPerFrame: 4),
    bytes: floatBytes([1, 2, 3, 4, 11, 12, 13, 14]),
    frameCount: 4,
    presentationTime: CMTime(value: 1, timescale: 48_000)
  )

  stream.emit(sample)
  _ = generation.ringBuffer.finishProducing()
  let blocks = drainSystemRing(generation.ringBuffer)

  #expect(blocks.first?.channels[0] == [1, 2, 3, 4])
  #expect(blocks.first?.channels[1] == [11, 12, 13, 14])
}

@Test func systemPaddedInterleavedStrideIsDropped() async throws {
  let stream = FakeSystemStream()
  let diagnostics = AudioSourceDiagnostics()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    diagnostics: diagnostics
  )
  try await source.start()
  let sample = try makeRawSampleBuffer(
    stream: makeFloat32Stream(sampleRate: 48_000, channels: 2, interleaved: true, bytesPerFrame: 12),
    bytes: floatBytes([1, 11, 0, 2, 12, 0]),
    frameCount: 2,
    presentationTime: CMTime(value: 1, timescale: 48_000)
  )

  stream.emit(sample)
  let snapshot = diagnostics.snapshot()

  #expect(snapshot.acceptedFrames == 0)
  #expect(snapshot.droppedFrames == 2)
  #expect(snapshot.gapFrames == 0)
}

@Test func systemOverflowReportsRingGapSeparatelyFromDrop() async throws {
  let stream = FakeSystemStream()
  let diagnostics = AudioSourceDiagnostics()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.05,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    diagnostics: diagnostics
  )
  try await source.start()
  let frames = 5_000
  var samples = [Float](repeating: 0.25, count: frames * 2)
  samples[0] = 1
  let sample = try makeRawSampleBuffer(
    stream: makeFloat32Stream(sampleRate: 48_000, channels: 2, interleaved: true, bytesPerFrame: 8),
    bytes: floatBytes(samples),
    frameCount: frames,
    presentationTime: CMTime(value: 1, timescale: 48_000)
  )

  stream.emit(sample)
  let snapshot = diagnostics.snapshot()

  #expect(snapshot.acceptedFrames == 2_400)
  #expect(snapshot.droppedFrames == 2_600)
  #expect(snapshot.gapFrames == 2_600)
}

@Test func systemIntegerPCMIsDropped() async throws {
  let stream = FakeSystemStream()
  let diagnostics = AudioSourceDiagnostics()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    diagnostics: diagnostics
  )
  try await source.start()
  var integerStream = makeFloat32Stream(
    sampleRate: 48_000,
    channels: 2,
    interleaved: true,
    bytesPerFrame: 8
  )
  integerStream.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
  let sample = try makeRawSampleBuffer(
    stream: integerStream,
    bytes: floatBytes([1, 11]),
    frameCount: 1,
    presentationTime: CMTime(value: 1, timescale: 48_000)
  )

  stream.emit(sample)
  let snapshot = diagnostics.snapshot()

  #expect(snapshot.acceptedFrames == 0)
  #expect(snapshot.droppedFrames == 1)
}

@Test func systemBigEndianFloat32IsDropped() async throws {
  let stream = FakeSystemStream()
  let diagnostics = AudioSourceDiagnostics()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    diagnostics: diagnostics
  )
  try await source.start()
  var bigEndian = makeFloat32Stream(
    sampleRate: 48_000,
    channels: 2,
    interleaved: true,
    bytesPerFrame: 8
  )
  bigEndian.mFormatFlags |= kAudioFormatFlagIsBigEndian
  let sample = try makeRawSampleBuffer(
    stream: bigEndian,
    bytes: floatBytes([1, 11]),
    frameCount: 1,
    presentationTime: CMTime(value: 1, timescale: 48_000)
  )

  stream.emit(sample)
  #expect(diagnostics.snapshot().acceptedFrames == 0)
  #expect(diagnostics.snapshot().droppedFrames == 1)
}

@Test func systemFloat64PCMIsDropped() async throws {
  let stream = FakeSystemStream()
  let diagnostics = AudioSourceDiagnostics()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    diagnostics: diagnostics
  )
  try await source.start()
  var doubleStream = makeFloat32Stream(
    sampleRate: 48_000,
    channels: 2,
    interleaved: true,
    bytesPerFrame: 16
  )
  doubleStream.mBitsPerChannel = 64
  let sample = try makeRawSampleBuffer(
    stream: doubleStream,
    bytes: doubleBytes([1, 11]),
    frameCount: 1,
    presentationTime: CMTime(value: 1, timescale: 48_000)
  )

  stream.emit(sample)
  let snapshot = diagnostics.snapshot()

  #expect(snapshot.acceptedFrames == 0)
  #expect(snapshot.droppedFrames == 1)
}

// MARK: - Microphone raw copy

@Test func microphoneInterleavedStereoDeinterleavesExactly() async throws {
  let interleaved = try makeInterleavedPCMBuffer(
    samples: [1, 11, 2, 12, 3, 13, 4, 14],
    sampleRate: 48_000,
    channels: 2
  )
  let engine = FakeMicrophoneEngine(format: interleaved.format)
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )
  try await source.start()
  let generation = await source.currentGeneration()

  engine.emit(interleaved, hostTime: 4_800)
  _ = generation.ringBuffer.finishProducing()
  let blocks = drainSystemRing(generation.ringBuffer)

  #expect(blocks.first?.channels[0] == [1, 2, 3, 4])
  #expect(blocks.first?.channels[1] == [11, 12, 13, 14])
  #expect(blocks.first?.hostTime == 4_800)
}

@Test func microphoneCurrentFormatMismatchFailsStart() async throws {
  let ring = try testRing(role: .microphone, sampleRate: 44_100, channelCount: 1)
  let engine = FakeMicrophoneEngine(format: try makeAudioFormat(sampleRate: 48_000, channels: 1))
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
  )

  await #expect(throws: AudioSourceError.self) {
    try await source.start()
  }

  #expect(engine.installCount == 0)
}

@Test func diagnosticsConcurrentReasonsStayCoherent() async {
  let diagnostics = AudioSourceDiagnostics()
  diagnostics.recordCallback(
    durationNanos: 1_000,
    acceptedFrames: 0,
    droppedFrames: 1,
    gapFrames: 0,
    dropReason: .closed
  )
  await withTaskGroup(of: Void.self) { group in
    for index in 0..<400 {
      group.addTask {
        diagnostics.recordCallback(
          durationNanos: Int64(index),
          acceptedFrames: 0,
          droppedFrames: 1,
          gapFrames: 0,
          dropReason: index.isMultiple(of: 2) ? .overflow : .invalidFormat
        )
      }
    }
  }
  let snapshot = diagnostics.snapshot()
  #expect(snapshot.callbackCount == 401)
  #expect(snapshot.droppedFrames == 401)
  let reason = snapshot.lastDropReason
  #expect(reason == .closed || reason == .overflow || reason == .invalidFormat)
}

@Test func retainedTailDrainsAndRetriesFinishForTask6() throws {
  let ring = try testRing(role: .system, capacitySeconds: 0.0501)
  #expect(ring.capacityFrames == 2_404)
  var samples = [Float](repeating: 0.25, count: 2_404 * 2)
  for index in samples.indices {
    samples[index] = Float(index % 17)
  }
  let write = samples.withUnsafeBufferPointer { buffer in
    ring.write(interleaved: buffer, frameCount: 2_404, hostTime: 1_000)
  }
  #expect(write.acceptedFrames == 2_404)
  let firstFinish = ring.finishProducing()
  #expect(firstFinish.retainedStagingFrames == 4)
  ring.requestClose()

  var delivered = 0
  for _ in 0..<5 {
    if let block = ring.read(maxFrames: 480).block {
      delivered += block.frameCount
    }
  }
  #expect(delivered == 2_400)
  let retry = ring.finishProducing()
  #expect(retry.retainedStagingFrames == 0)
  #expect(retry.flushedFrames == 4)
  let tail = ring.read(maxFrames: 480)
  #expect(tail.block?.frameCount == 4)
  #expect(tail.gapFrames == 0)
  let terminal = ring.read(maxFrames: 480)
  #expect(terminal.block == nil)
  #expect(terminal.gapFrames == 0)
  #expect(terminal.isClosedAndEmpty)
}
