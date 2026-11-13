import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

// MARK: - Lifecycle and join

@Test func callbackGateRejectsConcurrentAndPostStopEntries() {
  let gate = AudioCallbackGate()

  #expect(gate.enter())
  #expect(gate.enter() == false)
  gate.leave()
  #expect(gate.enter())
  gate.leave()
  gate.beginStop()
  #expect(gate.enter() == false)
}

@Test func callbackGateJoinReportsTimeoutUntilAdmittedCallbackLeaves() async {
  let gate = AudioCallbackGate()
  #expect(gate.enter())
  let timedOut = await gate.waitUntilIdle(timeout: .milliseconds(20))
  #expect(timedOut == false)

  gate.leave()
  let joined = await gate.waitUntilIdle(timeout: .milliseconds(200))
  #expect(joined)
}

@Test func systemRetainedHandlerAfterStopCannotWriteOrCountCallback() async throws {
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
  let generation = await source.currentGeneration()
  await source.stop()
  let accepted = generation.ringBuffer.stats.acceptedFrames

  stream.emitRetainedAfterRemoval(
    try makeSystemSampleBuffer(channels: [[1, 11, 2, 12]], hostTime: 9_000)
  )

  #expect(generation.ringBuffer.stats.acceptedFrames == accepted)
  #expect(diagnostics.snapshot().callbackCount == 0)
}

@Test func microphoneRetainedTapAfterStopCannotWriteOrCountCallback() async throws {
  let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let diagnostics = AudioSourceDiagnostics()
  let engine = FakeMicrophoneEngine(format: format)
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    diagnostics: diagnostics
  )
  try await source.start()
  let generation = await source.currentGeneration()
  await source.stop()
  let accepted = generation.ringBuffer.stats.acceptedFrames
  let buffer = try makeMicrophoneBuffer(
    sampleRate: 48_000,
    channels: 2,
    frames: 2,
    value: 0.5
  )

  engine.emitRetainedAfterRemoval(buffer, hostTime: 8_000)

  #expect(generation.ringBuffer.stats.acceptedFrames == accepted)
  #expect(diagnostics.snapshot().callbackCount == 0)
}

// MARK: - Replacement rollback

@Test func systemReplacementInstallFailureKeepsOldStreamHealthy() async throws {
  let first = FakeSystemStream()
  let second = FakeSystemStream()
  second.installFails = true
  let streams = [first, second]
  var index = 0
  let factory = FakeSystemAudioStreamFactory(make: {
    let stream = streams[index]
    index += 1
    return stream
  })
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: factory
  )
  try await source.start()
  let old = await source.currentGeneration()

  let preparation = await source.prepareReconfiguration(
    AudioDeviceChangeEvent(
      role: .system,
      deviceID: "opaque-output",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )

  guard case .unchangedOnFailure = preparation else {
    Issue.record("expected replacement install failure")
    return
  }
  #expect(first.removeCount == 0)
  #expect(first.stopCaptureCount == 0)
  #expect(second.installCount == 1)
  #expect(second.removeCount == 1)
  #expect(second.startCaptureCount == 0)
  #expect(old.ringBuffer.isClosedAndEmpty == false)
  #expect(await source.isRunning())
}

@Test func systemReplacementStartFailureStopsOnlyNewStream() async throws {
  let first = FakeSystemStream()
  let second = FakeSystemStream()
  second.startFails = true
  let streams = [first, second]
  var index = 0
  let factory = FakeSystemAudioStreamFactory(make: {
    let stream = streams[index]
    index += 1
    return stream
  })
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: factory
  )
  try await source.start()
  let old = await source.currentGeneration()

  let preparation = await source.prepareReconfiguration(
    AudioDeviceChangeEvent(
      role: .system,
      deviceID: "opaque-output",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )

  guard case .unchangedOnFailure = preparation else {
    Issue.record("expected replacement start failure")
    return
  }
  #expect(first.removeCount == 0)
  #expect(first.stopCaptureCount == 0)
  #expect(second.removeCount == 1)
  #expect(second.stopCaptureCount == 1)
  #expect(old.ringBuffer.isClosedAndEmpty == false)
}

// MARK: - Microphone failures and rollback

@Test func microphoneInstallFailureRollsBackWithoutStartingEngine() async throws {
  let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let engine = FakeMicrophoneEngine(format: format)
  engine.installFails = true
  let monitor = FakeDeviceMonitor()
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: monitor,
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )

  await #expect(throws: AudioSourceError.self) {
    try await source.start()
  }

  #expect(engine.startCount == 0)
  #expect(engine.removeCount == 0)
  #expect(monitor.startCount == 0)
  #expect(ring.isClosedAndEmpty == true)
}

@Test func microphoneEngineStartFailureRemovesTap() async throws {
  let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let engine = FakeMicrophoneEngine(format: format)
  engine.startFails = true
  let monitor = FakeDeviceMonitor()
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: monitor,
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )

  await #expect(throws: AudioSourceError.self) {
    try await source.start()
  }

  #expect(engine.installCount == 1)
  #expect(engine.removeCount == 1)
  #expect(monitor.startCount == 0)
  #expect(ring.isClosedAndEmpty == true)
}

@Test func microphoneMonitorFailureStopsEngineAndRemovesTap() async throws {
  let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let engine = FakeMicrophoneEngine(format: format)
  let monitor = FakeDeviceMonitor()
  monitor.startFails = true
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: monitor,
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )

  await #expect(throws: AudioSourceError.self) {
    try await source.start()
  }

  #expect(engine.installCount == 1)
  #expect(engine.removeCount == 1)
  #expect(engine.stopCount == 1)
  #expect(monitor.startCount == 1)
  #expect(ring.isClosedAndEmpty == true)
}

@Test func microphoneFailedReplacementRestoresOldFormatAndRing() async throws {
  let oldFormat = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let newFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
  let engine = FakeMicrophoneEngine(format: oldFormat)
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )
  try await source.start()
  let old = await source.currentGeneration()

  engine.currentFormatOverride = newFormat
  let preparation = await source.prepareReconfiguration(
    AudioDeviceChangeEvent(
      role: .microphone,
      deviceID: "opaque-input",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )
  guard case .prepared(let newGeneration) = preparation else {
    Issue.record("expected prepared replacement")
    return
  }
  engine.failNextInstall = true

  #expect(await source.commitReconfiguration(newGeneration) == false)
  #expect(engine.tapFormat?.sampleRate == 48_000)
  #expect(await source.currentGeneration().id == old.id)
  #expect(old.ringBuffer.isClosedAndEmpty == false)
  #expect(newGeneration.ringBuffer.isClosedAndEmpty == true)

  let buffer = try makeMicrophoneBuffer(sampleRate: 48_000, channels: 2, frames: 2, value: 0.25)
  engine.emit(buffer, hostTime: 5_000)
  _ = old.ringBuffer.finishProducing()
  let blocks = drainSystemRing(old.ringBuffer)
  #expect(blocks.first?.channels[0] == [0.25, 0.25])
}

@Test func microphoneNilCurrentFormatFailsStart() async throws {
  let ring = try testRing(role: .microphone)
  let engine = FakeMicrophoneEngine(format: nil)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )

  await #expect(throws: AudioSourceError.self) {
    try await source.start()
  }

  #expect(engine.installCount == 0)
  #expect(ring.isClosedAndEmpty == true)
}

@Test func microphoneStoppedEngineRestartsOnCommit() async throws {
  let oldFormat = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let newFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
  let engine = FakeMicrophoneEngine(format: oldFormat)
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )
  try await source.start()
  engine.currentFormatOverride = newFormat
  engine.emitConfigurationChange()
  #expect(engine.isRunning == false)

  let preparation = await source.prepareReconfiguration(
    AudioDeviceChangeEvent(
      role: .microphone,
      deviceID: "opaque-input",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )
  guard case .prepared(let generation) = preparation else {
    Issue.record("expected stopped-engine reconfiguration")
    return
  }
  #expect(await source.commitReconfiguration(generation) == true)
  #expect(engine.startCount == 2)
  #expect(engine.isRunning)
  #expect(await source.currentGeneration().id == generation.id)
}

@Test func microphoneConfigurationChangeBroadcastsCurrentFormat() async throws {
  let oldFormat = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let newFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
  let engine = FakeMicrophoneEngine(format: oldFormat)
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: engine,
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )
  let changes = source.makeDeviceChangeStream()
  try await source.start()

  let receiver = Task { await changes.first(where: { _ in true }) }
  engine.currentFormatOverride = newFormat
  engine.emitConfigurationChange()
  let event = await receiver.value

  #expect(event?.role == .microphone)
  #expect(event?.format.sampleRate == 44_100)
  #expect(event?.format.channelCount == 1)
  await source.stop()
}

// MARK: - System-only monitoring

@Test func coreAudioMonitorDeclaresDefaultAndSameDeviceSelectors() {
  let selectors = CoreAudioDeviceChangeMonitor.monitoredSelectors
  #expect(selectors.contains(kAudioHardwarePropertyDefaultInputDevice))
  #expect(selectors.contains(kAudioHardwarePropertyDefaultOutputDevice))
  #expect(selectors.contains(kAudioDevicePropertyNominalSampleRate))
  #expect(selectors.contains(kAudioDevicePropertyStreamConfiguration))
}

@Test func systemOnlyMonitorRegistersAndEmitsDeviceChanges() async throws {
  let stream = FakeSystemStream()
  let monitor = FakeDeviceMonitor()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream }),
    deviceMonitor: monitor
  )
  let changes = source.makeDeviceChangeStream()
  try await source.start()
  #expect(monitor.startCount == 1)

  let receiver = Task { await changes.first(where: { _ in true }) }
  monitor.emit(
    AudioDeviceChangeEvent(
      role: .system,
      deviceID: "opaque-output",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )
  let event = await receiver.value
  #expect(event?.format.sampleRate == 44_100)

  await source.stop()
  #expect(monitor.stopCount == 1)
}

@Test func stoppedSystemSourceRejectsSameGenerationCommit() async throws {
  let stream = FakeSystemStream()
  let source = try SystemAudioSource(
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
    hostTicksPerSecond: 1_000_000_000,
    capacitySeconds: 0.1,
    factory: FakeSystemAudioStreamFactory(make: { stream })
  )
  try await source.start()
  let generation = await source.currentGeneration()
  await source.stop()

  #expect(await source.commitReconfiguration(generation) == false)
  #expect(await source.isProducerJoined())
}

@Test func stoppedMicrophoneRejectsSameGenerationCommit() async throws {
  let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
  let ring = try testRing(role: .microphone)
  let source = makeMicrophoneSource(
    ring: ring,
    authorizer: FakeMicrophoneAuthorizer(state: .authorized),
    engine: FakeMicrophoneEngine(format: format),
    monitor: FakeDeviceMonitor(),
    format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  )
  try await source.start()
  let generation = await source.currentGeneration()
  await source.stop()

  #expect(await source.commitReconfiguration(generation) == false)
  #expect(await source.isProducerJoined())
}

final class FakePropertyListenerRegistrar: AudioPropertyListenerRegistrar, @unchecked Sendable {
  private let lock = NSLock()
  private var addCount = 0
  private var removeCount = 0
  private var failNextAdd = false

  var removed: Int {
    lock.lock()
    defer { lock.unlock() }
    return removeCount
  }

  func failNextAddition() {
    lock.lock()
    failNextAdd = true
    lock.unlock()
  }

  func add(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: AudioObjectPropertyListenerBlock
  ) -> OSStatus {
    lock.lock()
    defer { lock.unlock() }
    if failNextAdd {
      failNextAdd = false
      return OSStatus(-1)
    }
    addCount += 1
    return noErr
  }

  func remove(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress,
    queue: DispatchQueue,
    block: AudioObjectPropertyListenerBlock
  ) {
    lock.lock()
    removeCount += 1
    lock.unlock()
  }
}

@Test func coreAudioRefreshKeepsOldRegistrationsWhenReplacementFails() throws {
  let registrar = FakePropertyListenerRegistrar()
  let format = AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
  let monitor = CoreAudioDeviceChangeMonitor(
    registrar: registrar,
    defaultDeviceProvider: { _ in 1 },
    formatProvider: { _, _ in format }
  )
  try monitor.start { _ in }
  let before = registrar.removed

  registrar.failNextAddition()
  monitor.refreshDeviceListenersForTesting()

  #expect(registrar.removed == before)
  #expect(monitor.lastReplacementFailed)
  monitor.refreshDeviceListenersForTesting()
  #expect(registrar.removed > before)
  #expect(monitor.lastReplacementFailed == false)
  monitor.stop()
}




@Test func shutdownWithUnjoinedProducerReportsIncompleteThenRetires() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let preparation = await controller.prepare(.system)
  #expect(
    isCommitted(
      await controller.commit(
        RouteEvent(atSample: 0, mode: .system, deviceID: nil),
        preparationID: preparation.preparationID
      )
    )
  )
  let old = try #require(await controller.currentGeneration(for: .system))
  system.producerJoined = false

  #expect(await controller.shutdown() == false)
  #expect(await controller.isShutdownComplete() == false)
  #expect(await controller.takeRetiredGenerations().isEmpty)

  system.producerJoined = true
  #expect(await controller.shutdown())
  let retired = await controller.takeRetiredGenerations()
  #expect(retired.contains(where: { $0.id == old.id }))
}
