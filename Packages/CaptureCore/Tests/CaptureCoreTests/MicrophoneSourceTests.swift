import AVFoundation
import Foundation
import Testing

@testable import CaptureCore

// MARK: - Shared fakes

final class FakeMicrophoneAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var state: MicrophoneAuthorizationState
    private var requests = 0

    init(state: MicrophoneAuthorizationState) {
        self.state = state
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func currentState() -> MicrophoneAuthorizationState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func requestAccess() async -> MicrophoneAuthorizationState {
        recordRequest()
    }

    func setState(_ newState: MicrophoneAuthorizationState) {
        lock.lock()
        state = newState
        lock.unlock()
    }

    private func recordRequest() -> MicrophoneAuthorizationState {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        return state
    }
}

final class FakeMicrophoneEngine: MicrophoneCaptureEngine,
    MicrophoneConfigurationChangeMonitoring, @unchecked Sendable
{
    private let lock = NSLock()
    private var hardwareFormat: AVAudioFormat?
    private var tapFormatStorage: AVAudioFormat?
    private var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var retainedHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var events: [String] = []
    private var running = false
    private var configurationHandler: (@Sendable () -> Void)?

    var installFails = false
    var startFails = false
    var startHook: (() -> Void)?
    var failNextInstall = false
    var onInstall: (() -> Void)?

    init(format: AVAudioFormat?) {
        hardwareFormat = format
    }

    var currentFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return hardwareFormat
    }

    var currentFormatOverride: AVAudioFormat? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return hardwareFormat
        }
        set {
            lock.lock()
            hardwareFormat = newValue
            lock.unlock()
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var installCount: Int { count("install") }
    var removeCount: Int { count("remove") }
    var startCount: Int { count("start") }
    var stopCount: Int { count("stop") }
    var eventLog: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var tapFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return tapFormatStorage
    }

    func installTap(
        format: AVAudioFormat,
        handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        lock.lock()
        let hook = onInstall
        lock.unlock()
        hook?()
        lock.lock()
        defer { lock.unlock() }
        events.append("install")
        if installFails || failNextInstall {
            failNextInstall = false
            throw AudioSourceError.installFailed("fake tap")
        }
        tapFormatStorage = format
        self.handler = handler
    }

    func removeTap() {
        lock.lock()
        defer { lock.unlock() }
        events.append("remove")
        retainedHandler = handler
        handler = nil
        tapFormatStorage = nil
    }

    func start() throws {
        lock.lock()
        let hook = startHook
        lock.unlock()
        hook?()
        lock.lock()
        defer { lock.unlock() }
        events.append("start")
        if startFails {
            throw AudioSourceError.startFailed("fake engine")
        }
        running = true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        events.append("stop")
        running = false
    }

    func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock()
        let callback = handler
        lock.unlock()
        callback?(buffer, AVAudioTime(hostTime: hostTime))
    }

    func emitRetainedAfterRemoval(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        lock.lock()
        let callback = retainedHandler
        lock.unlock()
        callback?(buffer, AVAudioTime(hostTime: hostTime))
    }

    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        configurationHandler = handler
        lock.unlock()
    }

    func emitConfigurationChange() {
        lock.lock()
        running = false
        let callback = configurationHandler
        lock.unlock()
        callback?()
    }

    private func count(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0 == event }.count
    }
}

final class FakeDeviceMonitor: AudioDeviceChangeMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AudioDeviceChangeEvent) -> Void)?
    private var starts = 0
    private var stops = 0

    var startFails = false
    var startHook: (() -> Void)?

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start(_ handler: @escaping @Sendable (AudioDeviceChangeEvent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        starts += 1
        startHook?()
        if startFails {
            throw AudioSourceError.installFailed("fake monitor")
        }
        self.handler = handler
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stops += 1
        handler = nil
    }

    func emit(_ event: AudioDeviceChangeEvent) {
        lock.lock()
        let callback = handler
        lock.unlock()
        callback?(event)
    }
}

func makeAudioFormat(
    sampleRate: Double,
    channels: AVAudioChannelCount
) throws -> AVAudioFormat {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
        throw AudioSourceError.invalidFormat
    }
    return format
}

func makeMicrophoneSource(
    ring: AudioSourceRingBuffer,
    authorizer: FakeMicrophoneAuthorizer,
    engine: FakeMicrophoneEngine,
    monitor: FakeDeviceMonitor,
    format: AudioSourceFormat,
    diagnostics: AudioSourceDiagnostics? = nil,
    joinTimeout: Duration = .seconds(2)
) -> MicrophoneSource {
    MicrophoneSource(
        ringBuffer: ring,
        authorizer: authorizer,
        engine: engine,
        deviceMonitor: monitor,
        format: format,
        hostTicksPerSecond: 1_000_000_000,
        machTicksPerSecond: 1_000_000_000,
        capacitySeconds: 0.1,
        joinTimeout: joinTimeout,
        diagnostics: diagnostics
    )
}

func makeMicrophoneBuffer(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    frames: Int,
    value: Float
) throws -> AVAudioPCMBuffer {
    let values = [[Float]](repeating: [Float](repeating: value, count: frames), count: Int(channels))
    return try AudioSampleBufferFactory.makePCMBuffer(channels: values, sampleRate: Int(sampleRate))
}

// MARK: - Microphone tests

@Test(arguments: [
    MicrophoneAuthorizationState.unknown,
    .denied,
    .restricted,
])
func startRejectsUnavailableAuthorizationWithoutPrompting(state: MicrophoneAuthorizationState) async throws {
    let native = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let ring = try testRing(role: .microphone)
    let authorizer = FakeMicrophoneAuthorizer(state: state)
    let engine = FakeMicrophoneEngine(format: native)
    let monitor = FakeDeviceMonitor()
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: authorizer,
        engine: engine,
        monitor: monitor,
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )

    await #expect(throws: AudioSourceError.self) {
        try await source.start()
    }

    #expect(authorizer.requestCount == 0)
    #expect(engine.installCount == 0)
    #expect(engine.startCount == 0)
    #expect(monitor.startCount == 0)
}

@Test func authorizedStartInstallsExactlyOneTap() async throws {
    let sourceFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
    let ring = try testRing(role: .microphone, sampleRate: 44_100, channelCount: 1)
    let authorizer = FakeMicrophoneAuthorizer(state: .authorized)
    let engine = FakeMicrophoneEngine(format: sourceFormat)
    let monitor = FakeDeviceMonitor()
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: authorizer,
        engine: engine,
        monitor: monitor,
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )

    try await source.start()

    #expect(engine.installCount == 1)
    #expect(engine.startCount == 1)
    #expect(monitor.startCount == 1)
    #expect(engine.tapFormat?.sampleRate == 44_100)
    #expect(engine.tapFormat?.channelCount == 1)
    #expect(authorizer.requestCount == 0)
}

@Test func callbackCopiesRawFortyFourPointOneKilohertzMonoFrames() async throws {
    let sourceFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
    let ring = try testRing(role: .microphone, sampleRate: 44_100, channelCount: 1)
    let engine = FakeMicrophoneEngine(format: sourceFormat)
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: FakeMicrophoneAuthorizer(state: .authorized),
        engine: engine,
        monitor: FakeDeviceMonitor(),
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
    try await source.start()
    let generation = await source.currentGeneration()
    let buffer = try makeMicrophoneBuffer(sampleRate: 44_100, channels: 1, frames: 1_024, value: 0.25)

    engine.emit(buffer, hostTime: 55_555)
    _ = generation.ringBuffer.finishProducing()
    let blocks = drainSystemRing(generation.ringBuffer)

    #expect(blocks.count == 1)
    #expect(blocks.first?.sampleRate == 44_100)
    #expect(blocks.first?.channelCount == 1)
    #expect(blocks.first?.frameCount == 1_024)
    #expect(blocks.first?.hostTime == 55_555)
    #expect(blocks.first?.channels[0].allSatisfy { $0 == 0.25 } == true)
}

@Test func callbackCopiesMatchingFormatWithoutChangingSamples() async throws {
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let ring = try testRing(role: .microphone)
    let engine = FakeMicrophoneEngine(format: format)
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: FakeMicrophoneAuthorizer(state: .authorized),
        engine: engine,
        monitor: FakeDeviceMonitor(),
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
    try await source.start()
    let generation = await source.currentGeneration()
    let buffer = try makeMicrophoneBuffer(sampleRate: 48_000, channels: 2, frames: 4, value: 0.5)

    engine.emit(buffer, hostTime: 7_777)
    _ = generation.ringBuffer.finishProducing()
    let blocks = drainSystemRing(generation.ringBuffer)

    #expect(blocks.count == 1)
    #expect(blocks.first?.frameCount == 4)
    #expect(blocks.first?.hostTime == 7_777)
    #expect(blocks.first?.channels[0] == [0.5, 0.5, 0.5, 0.5])
    #expect(blocks.first?.channels[1] == [0.5, 0.5, 0.5, 0.5])
}

@Test func deviceChangeRebuildsGenerationFromActualInputFormat() async throws {
    let sourceFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
    let ring = try testRing(role: .microphone, sampleRate: 44_100, channelCount: 1)
    let engine = FakeMicrophoneEngine(format: sourceFormat)
    let monitor = FakeDeviceMonitor()
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: FakeMicrophoneAuthorizer(state: .authorized),
        engine: engine,
        monitor: monitor,
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
    try await source.start()
    let oldGeneration = await source.currentGeneration()
    engine.currentFormatOverride = try makeAudioFormat(sampleRate: 48_000, channels: 1)

    let preparation = await source.prepareReconfiguration(
        AudioDeviceChangeEvent(
            role: .microphone,
            deviceID: "opaque-input",
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
    )
    guard case .prepared(let newGeneration) = preparation else {
        Issue.record("expected prepared device change")
        return
    }
    #expect(newGeneration.id != oldGeneration.id)
    #expect(newGeneration.format.sampleRate == 48_000)
    #expect(engine.installCount == 1)

    #expect(await source.commitReconfiguration(newGeneration) == true)
    #expect(engine.installCount == 2)
    #expect(engine.removeCount == 1)
    #expect(engine.stopCount == 0)
    #expect(oldGeneration.ringBuffer.isClosedAndEmpty == true)
    let active = await source.currentGeneration()
    #expect(active.id == newGeneration.id)
}

@Test func staleDeviceEventIsRejectedBeforeReplacingTap() async throws {
    let sourceFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
    let ring = try testRing(role: .microphone, sampleRate: 44_100, channelCount: 1)
    let engine = FakeMicrophoneEngine(format: sourceFormat)
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: FakeMicrophoneAuthorizer(state: .authorized),
        engine: engine,
        monitor: FakeDeviceMonitor(),
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
    try await source.start()

    let preparation = await source.prepareReconfiguration(
        AudioDeviceChangeEvent(
            role: .microphone,
            deviceID: "opaque-input",
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
    )

    guard case .unchangedOnFailure = preparation else {
        Issue.record("expected stale device event rejection")
        return
    }
    #expect(engine.installCount == 1)
}

@Test func stopReleasesTapEngineAndMonitor() async throws {
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let ring = try testRing(role: .microphone)
    let engine = FakeMicrophoneEngine(format: format)
    let monitor = FakeDeviceMonitor()
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: FakeMicrophoneAuthorizer(state: .authorized),
        engine: engine,
        monitor: monitor,
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
    try await source.start()

    await source.stop()

    #expect(engine.removeCount == 1)
    #expect(engine.stopCount == 1)
    #expect(monitor.stopCount == 1)
    let finalGeneration = await source.currentGeneration()
    #expect(finalGeneration.ringBuffer.isClosedAndEmpty == true)
}

@Test func restartAfterCloseUsesFreshRing() async throws {
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let ring = try testRing(role: .microphone)
    let engine = FakeMicrophoneEngine(format: format)
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: FakeMicrophoneAuthorizer(state: .authorized),
        engine: engine,
        monitor: FakeDeviceMonitor(),
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
    try await source.start()
    let first = await source.currentGeneration()
    await source.stop()

    try await source.start()
    let second = await source.currentGeneration()

    #expect(first.id != second.id)
    #expect(first.ringBuffer !== second.ringBuffer)
    #expect(first.ringBuffer.isClosedAndEmpty == true)
    #expect(second.ringBuffer.isClosedAndEmpty == false)
    #expect(engine.installCount == 2)
}

@Test func deviceChangeStreamReceivesMonitorEvents() async throws {
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let ring = try testRing(role: .microphone)
    let monitor = FakeDeviceMonitor()
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: FakeMicrophoneAuthorizer(state: .authorized),
        engine: FakeMicrophoneEngine(format: format),
        monitor: monitor,
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
    let changes = source.makeDeviceChangeStream()
    try await source.start()
    let event = AudioDeviceChangeEvent(
        role: .microphone,
        deviceID: "opaque-input",
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )

    let receiver = Task { await changes.first(where: { _ in true }) }
    monitor.emit(event)
    let received = await receiver.value

    #expect(received?.deviceID == "opaque-input")
    #expect(received?.format == event.format)
    await source.stop()
}

@Test func deniedRestartDoesNotPromptOrInstallAnotherTap() async throws {
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let ring = try testRing(role: .microphone)
    let authorizer = FakeMicrophoneAuthorizer(state: .authorized)
    let engine = FakeMicrophoneEngine(format: format)
    let source = makeMicrophoneSource(
        ring: ring,
        authorizer: authorizer,
        engine: engine,
        monitor: FakeDeviceMonitor(),
        format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
    try await source.start()
    await source.stop()
    authorizer.setState(.denied)

    await #expect(throws: AudioSourceError.self) {
        try await source.start()
    }

    let after = await source.currentGeneration()
    #expect(after.ringBuffer.isClosedAndEmpty == true)
    #expect(authorizer.requestCount == 0)
    #expect(engine.installCount == 1)
}
