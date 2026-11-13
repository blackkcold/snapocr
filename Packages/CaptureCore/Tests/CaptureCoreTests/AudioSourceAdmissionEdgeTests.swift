import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import Testing

@testable import CaptureCore

final class TestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var timedOut = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var isSignaled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return signaled
  }

  func wait(timeout: Duration = .seconds(5)) async -> Bool {
    if isSignaled {
      return true
    }
    let timeoutTask = Task.detached { [self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      markTimedOutAndSignal()
    }
    await withCheckedContinuation { continuation in
      register(continuation)
    }
    timeoutTask.cancel()
    return !isTimedOut
  }

  private var isTimedOut: Bool {
    lock.lock()
    defer { lock.unlock() }
    return timedOut
  }

  private func markTimedOutAndSignal() {
    lock.lock()
    timedOut = true
    lock.unlock()
    signal()
  }

  func signal() {
    lock.lock()
    guard !signaled else {
      lock.unlock()
      return
    }
    signaled = true
    let pending = waiters
    waiters = []
    lock.unlock()
    for continuation in pending {
      continuation.resume()
    }
  }

  private func register(_ continuation: CheckedContinuation<Void, Never>) {
    lock.lock()
    if signaled {
      lock.unlock()
      continuation.resume()
      return
    }
    waiters.append(continuation)
    lock.unlock()
  }
}

final class TestSystemSample: @unchecked Sendable {
  let value: CMSampleBuffer
  init(_ value: CMSampleBuffer) { self.value = value }
}

final class TestPCMBuffer: @unchecked Sendable {
  let value: AVAudioPCMBuffer
  init(_ value: AVAudioPCMBuffer) { self.value = value }
}


@Suite(.serialized)
struct AudioSourceAdmissionEdgeTests {
    @Test func systemNativeStopThenStartCreatesFreshGeneration() async throws {
    let first = FakeSystemStream()
    let second = FakeSystemStream()
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
    await first.stopCapture()
    #expect(await source.isRunning() == false)

    try await source.start()
    let fresh = await source.currentGeneration()

    #expect(fresh.id != old.id)
    #expect(fresh.ringBuffer !== old.ringBuffer)
    #expect(old.ringBuffer.isClosedAndEmpty == true)
    #expect(await source.isRunning())
    #expect(factory.makeCount == 2)
  }

  @Test func microphoneNativeStopThenStartCreatesFreshGeneration() async throws {
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let engine = FakeMicrophoneEngine(format: format)
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
    engine.stop()
    #expect(await source.isRunning() == false)

    try await source.start()
    let fresh = await source.currentGeneration()

    #expect(fresh.id != old.id)
    #expect(fresh.ringBuffer !== old.ringBuffer)
    #expect(old.ringBuffer.isClosedAndEmpty == true)
    #expect(await source.isRunning())
  }

  @Test func controllerNativeStopPrunesThroughStopAndRetiresJoinedRing() async throws {
    let ring = try testRing(role: .system)
    let stream = FakeSystemStream()
    let source = SystemAudioSource(
      ringBuffer: ring,
      format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
      hostTicksPerSecond: 1_000_000_000,
      capacitySeconds: 0.1,
      factory: FakeSystemAudioStreamFactory(make: { stream })
    )
    let controller = AudioRouteController(
      authorizer: FakeMicrophoneAuthorizer(state: .authorized),
      sources: [.system: source]
    )
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
    await stream.stopCapture()

    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await source.isProducerJoined())
    let retired = await controller.takeRetiredGenerations()
    #expect(retired.contains(where: { $0.id == old.id }))
    #expect(old.ringBuffer.isClosedAndEmpty == true)
  }


  @Test func systemReplacementStartFailureAfterAdmittedCallback() async throws {
    let first = FakeSystemStream()
    let second = FakeSystemStream()
    second.startFails = true
    let admission = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let callbackQueue = DispatchQueue(label: "test.system.replacement")
    let sample = try makeSystemSampleBuffer(channels: [[1, 11]], hostTime: 200)
    let replacementSample = TestSystemSample(sample)
    let admitted = DispatchSemaphore(value: 0)
    second.onStartCapture = {
      callbackQueue.async { second.emit(replacementSample.value) }
      _ = admitted.wait(timeout: .now() + 1)
    }
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
      joinTimeout: .milliseconds(50),
      factory: factory
    )
    source.admissionTestHook = {
      admission.signal()
      admitted.signal()
      release.wait()
    }
    try await source.start()
    let old = await source.currentGeneration()
    let preparationTask = Task {
      await source.prepareReconfiguration(
        AudioDeviceChangeEvent(
          role: .system,
          deviceID: "opaque-output",
          format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        )
      )
    }
    #expect(await admission.wait())
    release.signal()
    let preparation = await preparationTask.value

    guard case .unchangedOnFailure = preparation else {
      Issue.record("expected replacement start failure")
      return
    }
    #expect(await source.isRunning())
    #expect(old.ringBuffer.isClosedAndEmpty == false)
    #expect(second.removeCount == 1)
    #expect(second.stopCaptureCount == 1)
  }

  @Test func microphoneFailedCommitAdmissionRetainsUntilJoined() async throws {
    let admission = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let callbackQueue = DispatchQueue(label: "test.microphone.commit")
    let oldFormat = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let newFormat = try makeAudioFormat(sampleRate: 44_100, channels: 1)
    let engine = FakeMicrophoneEngine(format: oldFormat)
    let ring = try testRing(role: .microphone)
    let source = makeMicrophoneSource(
      ring: ring,
      authorizer: FakeMicrophoneAuthorizer(state: .authorized),
      engine: engine,
      monitor: FakeDeviceMonitor(),
      format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
      joinTimeout: .milliseconds(50)
    )
    source.admissionTestHook = {
      admission.signal()
      release.wait()
    }
    try await source.start()
    let old = await source.currentGeneration()
    let buffer = try makeMicrophoneBuffer(sampleRate: 48_000, channels: 2, frames: 2, value: 0.5)
    let bufferBox = TestPCMBuffer(buffer)
    callbackQueue.async { engine.emit(bufferBox.value, hostTime: 300) }
    #expect(await admission.wait())
    engine.currentFormatOverride = newFormat

    let preparation = await source.prepareReconfiguration(
      AudioDeviceChangeEvent(
        role: .microphone,
        deviceID: "opaque-input",
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
      )
    )
    guard case .prepared(let replacement) = preparation else {
      Issue.record("expected prepared mic replacement")
      return
    }
    engine.failNextInstall = true
    #expect(await source.commitReconfiguration(replacement) == false)
    #expect(await source.isProducerJoined() == false)
    for _ in 0..<3 {
      await #expect(throws: AudioSourceError.self) {
        try await source.start()
      }
      let refused = await source.prepareReconfiguration(
        AudioDeviceChangeEvent(
          role: .microphone,
          deviceID: "opaque-input",
          format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        )
      )
      guard case .unchangedOnFailure = refused else {
        Issue.record("expected mic transition refusal while unjoined")
        return
      }
    }
    release.signal()
    for _ in 0..<100 {
      await Task.yield()
    }
    #expect(await source.isProducerJoined())
    try await source.start()
    let fresh = await source.currentGeneration()
    #expect(fresh.id != old.id)
    #expect(fresh.ringBuffer !== old.ringBuffer)
    #expect(fresh.format.sampleRate == 44_100)
  }

  @Test func systemReplacementInstallFailureWithOldAdmissionKeepsOldRing() async throws {
    let first = FakeSystemStream()
    let second = FakeSystemStream()
    second.installFails = true
    let admission = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let callbackQueue = DispatchQueue(label: "test.system.install")
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
    source.admissionTestHook = {
      admission.signal()
      release.wait()
    }
    try await source.start()
    let old = await source.currentGeneration()
    let sample = try makeSystemSampleBuffer(channels: [[1, 11]], hostTime: 400)
    let sampleBox = TestSystemSample(sample)
    callbackQueue.async { first.emit(sampleBox.value) }
    #expect(await admission.wait())
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
    #expect(old.ringBuffer.isClosedAndEmpty == false)
    #expect(second.removeCount == 1)
    #expect(first.removeCount == 0)
    release.signal()
    for _ in 0..<100 {
      await Task.yield()
    }
    #expect(await source.isRunning())
  }

  @Test func reuseNativeStopDoesNotStartBorrowedVideoStream() async throws {
    let shared = FakeSystemStream()
    try await shared.startCapture()
    let ring = try testRing(role: .system)
    let source = SystemAudioSource(
      ringBuffer: ring,
      format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
      hostTicksPerSecond: 1_000_000_000,
      stream: shared
    )
    try await source.start()
    await shared.stopCapture()

    await #expect(throws: AudioSourceError.self) {
      try await source.start()
    }
    #expect(shared.startCaptureCount == 1)
    #expect(shared.stopCaptureCount == 1)
  }

  @Test func microphoneEngineStartFailureAdmissionJoinsBeforeFinalize() async throws {
    let admission = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let engine = FakeMicrophoneEngine(format: format)
    let ring = try testRing(role: .microphone)
    let buffer = try makeMicrophoneBuffer(sampleRate: 48_000, channels: 2, frames: 2, value: 0.5)
    let bufferBox = TestPCMBuffer(buffer)
    let source = makeMicrophoneSource(
      ring: ring,
      authorizer: FakeMicrophoneAuthorizer(state: .authorized),
      engine: engine,
      monitor: FakeDeviceMonitor(),
      format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
    source.admissionTestHook = {
      admission.signal()
      release.wait()
    }
    engine.startFails = true
    engine.startHook = {
      engine.emit(bufferBox.value, hostTime: 500)
    }
    let startTask = Task { try await source.start() }
    #expect(await admission.wait())
    #expect(ring.isClosedAndEmpty == false)
    release.signal()
    await #expect(throws: AudioSourceError.self) {
      try await startTask.value
    }
    #expect(await source.isProducerJoined())
  }

  @Test func microphoneMonitorFailureAdmissionJoinsBeforeFinalize() async throws {
    let admission = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let format = try makeAudioFormat(sampleRate: 48_000, channels: 2)
    let engine = FakeMicrophoneEngine(format: format)
    let monitor = FakeDeviceMonitor()
    let ring = try testRing(role: .microphone)
    let buffer = try makeMicrophoneBuffer(sampleRate: 48_000, channels: 2, frames: 2, value: 0.5)
    let bufferBox = TestPCMBuffer(buffer)
    let source = makeMicrophoneSource(
      ring: ring,
      authorizer: FakeMicrophoneAuthorizer(state: .authorized),
      engine: engine,
      monitor: monitor,
      format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2)
    )
    source.admissionTestHook = {
      admission.signal()
      release.wait()
    }
    monitor.startFails = true
    monitor.startHook = {
      engine.emit(bufferBox.value, hostTime: 600)
    }
    let startTask = Task { try await source.start() }
    #expect(await admission.wait())
    #expect(ring.isClosedAndEmpty == false)
    release.signal()
    await #expect(throws: AudioSourceError.self) {
      try await startTask.value
    }
    #expect(await source.isProducerJoined())
  }

  @Test func microphoneFailedInstallAndRestoreWithAdmittedOldCallback() async throws {
    let admission = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let installed = TestSignal()
    let callbackQueue = DispatchQueue(label: "test.microphone.restore")
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
    source.admissionTestHook = {
      admission.signal()
      release.wait()
    }
    try await source.start()
    let old = await source.currentGeneration()
    let buffer = try makeMicrophoneBuffer(sampleRate: 48_000, channels: 2, frames: 2, value: 0.5)
    let bufferBox = TestPCMBuffer(buffer)
    callbackQueue.async { engine.emit(bufferBox.value, hostTime: 700) }
    #expect(await admission.wait())
    engine.currentFormatOverride = newFormat
    let preparation = await source.prepareReconfiguration(
      AudioDeviceChangeEvent(
        role: .microphone,
        deviceID: "opaque-input",
        format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
      )
    )
    guard case .prepared(let replacement) = preparation else {
      Issue.record("expected prepared mic replacement")
      return
    }
    engine.installFails = true
    engine.onInstall = { installed.signal() }
    let commitTask = Task { await source.commitReconfiguration(replacement) }
    #expect(await installed.wait())
    release.signal()
    #expect(await commitTask.value == false)
    #expect(await source.isRunning() == false)
    engine.installFails = false
    try await source.start()
    let fresh = await source.currentGeneration()
    #expect(fresh.id != old.id)
    #expect(fresh.ringBuffer !== old.ringBuffer)
    #expect(fresh.format.sampleRate == 44_100)
  }

  @Test func systemStopAdmissionRetainsThenRecoversFreshGeneration() async throws {
    let admission = TestSignal()
    let release = DispatchSemaphore(value: 0)
    let callbackQueue = DispatchQueue(label: "test.system.stop.admission")
    let first = FakeSystemStream()
    let second = FakeSystemStream()
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
      joinTimeout: .milliseconds(50),
      factory: factory
    )
    source.admissionTestHook = {
      admission.signal()
      release.wait()
    }
    try await source.start()
    let old = await source.currentGeneration()
    let sample = try makeSystemSampleBuffer(channels: [[1, 11]], hostTime: 800)
    let sampleBox = TestSystemSample(sample)
    callbackQueue.async { first.emit(sampleBox.value) }
    #expect(await admission.wait())
    await source.stop()
    #expect(old.ringBuffer.isClosedAndEmpty == false)
    #expect(await source.isProducerJoined() == false)
    release.signal()
    for _ in 0..<100 {
      await Task.yield()
    }
    #expect(await source.isProducerJoined())
    try await source.start()
    let fresh = await source.currentGeneration()
    #expect(fresh.id != old.id)
    #expect(factory.makeCount == 2)
  }
}
