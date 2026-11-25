import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Testing

@testable import CaptureCore

// MARK: - Shared fakes

final class FakeSystemStream: OwnedSystemAudioStreaming, @unchecked Sendable {
    let streamID = UUID()
    private let lock = NSLock()
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    private var retainedHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var running = false
    private var events: [String] = []

    var installFails = false
    var startFails = false
    var onStartCapture: (@Sendable () -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var installCount: Int { count("install") }
    var removeCount: Int { count("remove") }
    var startCaptureCount: Int { count("startCapture") }
    var stopCaptureCount: Int { count("stopCapture") }
    var eventLog: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func installAudioOutput(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        events.append("install")
        if installFails {
            throw AudioSourceError.installFailed("fake install")
        }
        self.handler = handler
    }

    func removeAudioOutput() async {
        recordRemove()
    }

    func startCapture() async throws {
        if recordStart() {
            throw AudioSourceError.startFailed("fake start")
        }
    }

    func stopCapture() async {
        recordStop()
    }

    private func recordRemove() {
        lock.lock()
        defer { lock.unlock() }
        events.append("remove")
        retainedHandler = handler
        handler = nil
    }

    private func recordStart() -> Bool {
        lock.lock()
        let hook = onStartCapture
        lock.unlock()
        hook?()
        lock.lock()
        defer { lock.unlock() }
        events.append("startCapture")
        if startFails {
            return true
        }
        running = true
        return false
    }

    private func recordStop() {
        lock.lock()
        defer { lock.unlock() }
        events.append("stopCapture")
        running = false
    }

    func emit(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let callback = handler
        lock.unlock()
        callback?(sampleBuffer)
    }

    func emitRetainedAfterRemoval(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let callback = retainedHandler
        lock.unlock()
        callback?(sampleBuffer)
    }

    private func count(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0 == event }.count
    }
}

final class FakeSystemAudioStreamFactory: SystemAudioStreamFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [FakeSystemStream] = []
    private let makeStreamBody: () throws -> FakeSystemStream

    init(make: @escaping () throws -> FakeSystemStream) {
        makeStreamBody = make
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streams.count
    }

    var madeStreams: [FakeSystemStream] {
        lock.lock()
        defer { lock.unlock() }
        return streams
    }

    func makeStream() async throws -> any OwnedSystemAudioStreaming {
        let stream = try makeStreamBody()
        record(stream)
        return stream
    }

    private func record(_ stream: FakeSystemStream) {
        lock.lock()
        streams.append(stream)
        lock.unlock()
    }
}

func testRing(
    role: RecordingTrackRole,
    sampleRate: Int = 48_000,
    channelCount: Int = 2,
    capacitySeconds: Double = 0.1
) throws -> AudioSourceRingBuffer {
    try AudioSourceRingBuffer(
        role: role,
        sampleRate: sampleRate,
        channelCount: channelCount,
        hostTicksPerSecond: 1_000_000_000,
        capacitySeconds: capacitySeconds
    )
}

func testGeneration(
    role: RecordingTrackRole,
    sampleRate: Int = 48_000,
    channelCount: Int = 2
) throws -> AudioSourceGeneration {
    AudioSourceGeneration(
        role: role,
        format: AudioSourceFormat(sampleRate: sampleRate, channelCount: channelCount),
        ringBuffer: try testRing(role: role, sampleRate: sampleRate, channelCount: channelCount)
    )
}

func makeSystemSource(
    factory: any SystemAudioStreamFactory,
    diagnostics: AudioSourceDiagnostics? = nil
) throws -> SystemAudioSource {
    try SystemAudioSource(
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
        hostTicksPerSecond: 1_000_000_000,
        capacitySeconds: 0.1,
        factory: factory,
        diagnostics: diagnostics,
        timestampMapper: AudioSourceTimestampMapper(
            hostTicksPerSecond: 1_000_000_000,
            anchorPTS: .zero,
            anchorHostTime: 0
        )
    )
}

func makeSystemSampleBuffer(
    channels: [[Float]],
    sampleRate: Int = 48_000,
    hostTime: UInt64 = 9_000
) throws -> CMSampleBuffer {
    let buffer = try AudioSampleBufferFactory.makePCMBuffer(channels: channels, sampleRate: sampleRate)
    let time = CMTime(value: Int64(hostTime), timescale: 1_000_000_000)
    return try AudioSampleBufferFactory.makeSampleBuffer(from: buffer, presentationTime: time)
}

func drainSystemRing(_ ring: AudioSourceRingBuffer, maxFrames: Int = 8_192) -> [AudioPCMBlock] {
    var blocks: [AudioPCMBlock] = []
    while let block = ring.read(maxFrames: maxFrames).block {
        blocks.append(block)
    }
    return blocks
}

// MARK: - System tests

@Test func ownedStartInstallsThenStartsCapture() async throws {
    let stream = FakeSystemStream()
    let factory = FakeSystemAudioStreamFactory(make: { stream })
    let source = try makeSystemSource(factory: factory)

    try await source.start()

    #expect(factory.makeCount == 1)
    #expect(stream.installCount == 1)
    #expect(stream.startCaptureCount == 1)
    #expect(stream.eventLog == ["install", "startCapture"])
}

@Test func ownedStopRemovesThenStopsCapture() async throws {
    let stream = FakeSystemStream()
    let factory = FakeSystemAudioStreamFactory(make: { stream })
    let source = try makeSystemSource(factory: factory)
    try await source.start()

    await source.stop()

    #expect(stream.removeCount == 1)
    #expect(stream.stopCaptureCount == 1)
    #expect(stream.eventLog == ["install", "startCapture", "remove", "stopCapture"])
    #expect(stream.isRunning == false)
}

@Test func ownedInstallFailureRollsBackWithRemoveOnly() async throws {
    let stream = FakeSystemStream()
    stream.installFails = true
    let factory = FakeSystemAudioStreamFactory(make: { stream })
    let source = try makeSystemSource(factory: factory)

    await #expect(throws: AudioSourceError.self) {
        try await source.start()
    }

    #expect(stream.installCount == 1)
    #expect(stream.removeCount == 1)
    #expect(stream.startCaptureCount == 0)
    #expect(stream.stopCaptureCount == 0)
}

@Test func ownedStartFailureRollsBackWithRemoveAndStop() async throws {
    let stream = FakeSystemStream()
    stream.startFails = true
    let factory = FakeSystemAudioStreamFactory(make: { stream })
    let source = try makeSystemSource(factory: factory)

    await #expect(throws: AudioSourceError.self) {
        try await source.start()
    }

    #expect(stream.installCount == 1)
    #expect(stream.startCaptureCount == 1)
    #expect(stream.removeCount == 1)
    #expect(stream.stopCaptureCount == 1)
}

@Test func reuseOnlyInstallsAndRemovesSharedOutput() async throws {
    let shared = FakeSystemStream()
    let generation = try testGeneration(role: .system)
    let source = SystemAudioSource(
        ringBuffer: generation.ringBuffer,
        format: generation.format,
        hostTicksPerSecond: 1_000_000_000,
        stream: shared
    )

    try await source.start()
    #expect(shared.installCount == 1)
    #expect(shared.startCaptureCount == 0)

    await source.stop()
    #expect(shared.removeCount == 1)
    #expect(shared.stopCaptureCount == 0)
    #expect(shared.eventLog == ["install", "remove"])
}

@Test func standaloneConfigurationIsAudioOnlyTwoByTwoLowFrameRate() {
    let configuration = SCKSystemAudioStreamFactory.makeConfiguration()

    #expect(configuration.width == 2)
    #expect(configuration.height == 2)
    #expect(configuration.capturesAudio == true)
    #expect(configuration.excludesCurrentProcessAudio == true)
    #expect(configuration.minimumFrameInterval == CMTime(value: 1, timescale: 1))
    #expect(configuration.showsCursor == false)
}

@Test func standaloneStartCreatesExactlyOneStream() async throws {
    let factory = FakeSystemAudioStreamFactory(make: { FakeSystemStream() })
    let source = try makeSystemSource(factory: factory)

    try await source.start()

    #expect(factory.makeCount == 1)
    await source.stop()
}

@Test func synthesizedSampleBufferExposesInterleavedAudioBufferList() throws {
    let sampleBuffer = try makeSystemSampleBuffer(
        channels: [
            [1, 2, 3, 4],
            [11, 12, 13, 14],
        ],
        hostTime: 1_000
    )
    let maximumBuffers = 8
    let size =
        MemoryLayout<AudioBufferList>.size
        + (maximumBuffers - 1) * MemoryLayout<AudioBuffer>.size
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: size,
        alignment: 16
    )
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    list.count = maximumBuffers
    var needed = 0
    let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &needed,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        blockBufferOut: nil
    )
    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
        bufferListSize: needed,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        blockBufferOut: &blockBuffer
    )

    #expect(sizeStatus == noErr)
    #expect(needed <= size)
    #expect(status == noErr)
    #expect(list.count == 1)
    #expect(list[0].mNumberChannels == 2)
    #expect(CMSampleBufferGetNumSamples(sampleBuffer) == 4)
}

@Test func callbackUsesFortyFourPointOneKilohertzMonoSourceRate() async throws {
    let ring = try testRing(role: .system, sampleRate: 44_100, channelCount: 1)
    let stream = FakeSystemStream()
    let factory = FakeSystemAudioStreamFactory(make: { stream })
    let source = SystemAudioSource(
        ringBuffer: ring,
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1),
        hostTicksPerSecond: 1_000_000_000,
        capacitySeconds: 0.1,
        factory: factory,
        timestampMapper: AudioSourceTimestampMapper(
            hostTicksPerSecond: 1_000_000_000,
            anchorPTS: .zero,
            anchorHostTime: 0
        )
    )
    try await source.start()
    let generation = await source.currentGeneration()
    let sampleBuffer = try makeSystemSampleBuffer(
        channels: [[3, 4, 5]],
        sampleRate: 44_100,
        hostTime: 8_888
    )

    stream.emit(sampleBuffer)
    _ = generation.ringBuffer.finishProducing()
    let blocks = drainSystemRing(generation.ringBuffer)

    #expect(blocks.count == 1)
    #expect(blocks.first?.sampleRate == 44_100)
    #expect(blocks.first?.channelCount == 1)
    #expect(blocks.first?.channels[0] == [3, 4, 5])
    #expect(blocks.first?.hostTime == 8_888)
}

@Test func callbackCopiesFramesAndPreservesFirstHostTime() async throws {
    let stream = FakeSystemStream()
    let factory = FakeSystemAudioStreamFactory(make: { stream })
    let diagnostics = AudioSourceDiagnostics()
    let source = try makeSystemSource(factory: factory, diagnostics: diagnostics)
    try await source.start()
    let generation = await source.currentGeneration()
    let sampleBuffer = try makeSystemSampleBuffer(
        channels: [
            [1, 2, 3, 4],
            [11, 12, 13, 14],
        ],
        hostTime: 123_456
    )

    stream.emit(sampleBuffer)
    let snapshot = diagnostics.snapshot()
    #expect(snapshot.callbackCount == 1)
    #expect(snapshot.acceptedFrames == 4)
    #expect(snapshot.droppedFrames == 0)
    _ = generation.ringBuffer.finishProducing()
    let blocks = drainSystemRing(generation.ringBuffer)

    #expect(blocks.count == 1)
    #expect(blocks.first?.hostTime == 123_456)
    #expect(blocks.first?.sampleRate == 48_000)
    #expect(blocks.first?.channelCount == 2)
    #expect(blocks.first?.frameCount == 4)
    #expect(blocks.first?.channels[0] == [1, 2, 3, 4])
    #expect(blocks.first?.channels[1] == [11, 12, 13, 14])
}

@Test func callbackAfterStopDoesNotReachRing() async throws {
    let stream = FakeSystemStream()
    let factory = FakeSystemAudioStreamFactory(make: { stream })
    let source = try makeSystemSource(factory: factory)
    try await source.start()
    let generation = await source.currentGeneration()
    await source.stop()
    let acceptedBefore = generation.ringBuffer.stats.acceptedFrames

    stream.emit(try makeSystemSampleBuffer(channels: [[1, 2, 3, 4]], hostTime: 7_000))

    #expect(generation.ringBuffer.stats.acceptedFrames == acceptedBefore)
}

@Test func ownedReconfigurationStartsNewStreamAndRetiresOldRing() async throws {
    let factory = FakeSystemAudioStreamFactory(make: { FakeSystemStream() })
    let source = try makeSystemSource(factory: factory)
    try await source.start()
    let oldGeneration = await source.currentGeneration()
    let event = AudioDeviceChangeEvent(
        role: .system,
        deviceID: "opaque-output",
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )

    let preparation = await source.prepareReconfiguration(event)
    guard case .prepared(let newGeneration) = preparation else {
        Issue.record("expected prepared reconfiguration")
        return
    }
    #expect(factory.makeCount == 2)
    #expect(newGeneration.id != oldGeneration.id)
    #expect(newGeneration.format.sampleRate == 44_100)
    #expect(oldGeneration.ringBuffer.isClosedAndEmpty == false)

    #expect(await source.commitReconfiguration(newGeneration) == true)
    #expect(factory.madeStreams[0].removeCount == 1)
    #expect(factory.madeStreams[0].stopCaptureCount == 1)
    #expect(factory.madeStreams[1].isRunning == true)
    #expect(oldGeneration.ringBuffer.isClosedAndEmpty == true)
    let active = await source.currentGeneration()
    #expect(active.id == newGeneration.id)
}

@Test func reuseReconfigurationIsRejectedWithoutTouchingVideoStream() async throws {
    let shared = FakeSystemStream()
    let generation = try testGeneration(role: .system)
    let source = SystemAudioSource(
        ringBuffer: generation.ringBuffer,
        format: generation.format,
        hostTicksPerSecond: 1_000_000_000,
        stream: shared
    )
    try await source.start()

    let preparation = await source.prepareReconfiguration(
        AudioDeviceChangeEvent(
            role: .system,
            deviceID: "opaque-output",
            format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        )
    )

    guard case .unchangedOnFailure = preparation else {
        Issue.record("expected unchanged failure for shared stream")
        return
    }
    #expect(shared.startCaptureCount == 0)
    #expect(shared.stopCaptureCount == 0)
    #expect(shared.installCount == 1)
}

@Test func diagnosticsBucketsCoverBoundariesAndOverflow() {
    let diagnostics = AudioSourceDiagnostics()
    let durations: [Int64] = [
        0,
        50_000,
        50_001,
        100_000,
        250_000,
        500_000,
        1_000_000,
        2_000_000,
        4_000_000,
        8_000_000,
        16_000_000,
        32_000_000,
        64_000_000,
        128_000_000,
        256_000_000,
        512_000_000,
        1_000_000_000,
        1_000_000_001,
    ]
    for duration in durations {
        diagnostics.recordCallback(
            durationNanos: duration,
            acceptedFrames: 1,
            droppedFrames: 0,
            gapFrames: 0,
            dropReason: nil
        )
    }

    let snapshot = diagnostics.snapshot()
    #expect(snapshot.callbackCount == Int64(durations.count))
    #expect(snapshot.acceptedFrames == Int64(durations.count))
    #expect(snapshot.durationBucketCounts.count == 16)
    #expect(snapshot.durationBucketCounts[0] == 2)
    #expect(snapshot.durationBucketCounts[1] == 2)
    #expect(snapshot.durationBucketCounts[14] == 1)
    #expect(snapshot.durationBucketCounts[15] == 1)
    #expect(snapshot.health == .healthy)
    #expect(snapshot.p99CallbackDurationNanos == nil)
}

@Test func diagnosticsSnapshotReportsDropsWithoutMutatingCounters() {
    let diagnostics = AudioSourceDiagnostics()
    diagnostics.recordCallback(
        durationNanos: 60_000,
        acceptedFrames: 0,
        droppedFrames: 128,
        gapFrames: 128,
        dropReason: .overflow
    )

    let first = diagnostics.snapshot()
    let second = diagnostics.snapshot()

    #expect(first == second)
    #expect(first.droppedFrames == 128)
    #expect(first.gapFrames == 128)
    #expect(first.lastDropReason == .overflow)
    #expect(first.health == .degraded)
}
