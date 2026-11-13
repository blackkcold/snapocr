import Foundation
import Testing

@testable import CaptureCore

// MARK: - Fake source

final class FakeFrameSource: AudioFrameSource, AudioSourceReconfigurationCancelling, @unchecked Sendable {
  let role: RecordingTrackRole
  private let lock = NSLock()
  private var active: AudioSourceGeneration
  private var prepared: AudioSourceGeneration?
  private var started = false
  private var starts = 0
  private var stops = 0
  private var commits = 0
  private var cancels = 0

  var startError: Error?
  var prepareResultOverride: AudioSourcePreparation?
  var commitAccepts = true
  var producerJoined = true
  var startDelay: Duration?
  var currentGenerationDelay: Duration?
  var prepareDelay: Duration?
  var stopOnRejectedCommit = false
  var stopDelay: Duration?
  var onStop: (() -> Void)?
  var onStart: (() -> Void)?

  init(role: RecordingTrackRole) throws {
    self.role = role
    active = try testGeneration(role: role)
  }

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

  var commitCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return commits
  }

  var cancelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancels
  }

  var activeGeneration: AudioSourceGeneration {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  var isStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  func currentGeneration() async -> AudioSourceGeneration {
    if let currentGenerationDelay {
      try? await Task.sleep(for: currentGenerationDelay)
    }
    return activeGeneration
  }

  func isRunning() async -> Bool {
    isStarted
  }

  func isProducerJoined() async -> Bool {
    producerJoined
  }

  func start() async throws {
    guard producerJoined else {
      throw AudioSourceError.unavailable("previous producer has not joined")
    }
    let next = try testGeneration(role: role)
    if let error = recordStart(next) {
      throw error
    }
    if let startDelay {
      try? await Task.sleep(for: startDelay)
    }
    onStart?()
  }

  func stop() async {
    onStop?()
    if let stopDelay {
      try? await Task.sleep(for: stopDelay)
    }
    guard let closing = recordStop() else { return }
    closing.ringBuffer.requestClose()
    _ = closing.ringBuffer.finishProducing()
  }

  func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
    if let prepareDelay {
      try? await Task.sleep(for: prepareDelay)
    }
    if let override = overrideSnapshot() {
      return override
    }
    guard let next = try? testGeneration(
      role: role,
      sampleRate: event.format.sampleRate,
      channelCount: event.format.channelCount
    ) else {
      return .unchangedOnFailure(reason: "fake generation failed")
    }
    recordPrepared(next)
    return .prepared(next)
  }

  func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
    switch recordCommit(generation) {
    case .rejected:
      return false
    case .acceptedWithoutOld:
      return true
    case .accepted(let old):
      old.ringBuffer.requestClose()
      _ = old.ringBuffer.finishProducing()
      return true
    }
  }

  func cancelReconfiguration(_ generationID: UUID) async {
    if let canceling = recordCancel(generationID) {
      canceling.ringBuffer.requestClose()
      _ = canceling.ringBuffer.finishProducing()
    }
  }

  private enum CommitOutcome {
    case rejected
    case acceptedWithoutOld
    case accepted(AudioSourceGeneration)
  }

  private func recordStart(_ next: AudioSourceGeneration) -> Error? {
    lock.lock()
    defer { lock.unlock() }
    starts += 1
    if let startError {
      return startError
    }
    if started {
      return nil
    }
    active = next
    started = true
    return nil
  }

  private func recordStop() -> AudioSourceGeneration? {
    lock.lock()
    defer { lock.unlock() }
    guard started else { return nil }
    stops += 1
    started = false
    return active
  }

  private func overrideSnapshot() -> AudioSourcePreparation? {
    lock.lock()
    defer { lock.unlock() }
    return prepareResultOverride
  }

  private func recordPrepared(_ next: AudioSourceGeneration) {
    lock.lock()
    prepared = next
    lock.unlock()
  }

  private func recordCommit(_ generation: AudioSourceGeneration) -> CommitOutcome {
    lock.lock()
    defer { lock.unlock() }
    commits += 1
    guard started else {
      return .rejected
    }
    if !commitAccepts {
      if stopOnRejectedCommit {
        started = false
      }
      return .rejected
    }
    if prepared?.id == generation.id {
      let old = active
      active = generation
      prepared = nil
      return .accepted(old)
    }
    if active.id == generation.id {
      return .acceptedWithoutOld
    }
    return .rejected
  }

  private func recordCancel(_ generationID: UUID) -> AudioSourceGeneration? {
    lock.lock()
    defer { lock.unlock() }
    guard prepared?.id == generationID else { return nil }
    let canceling = prepared
    prepared = nil
    cancels += 1
    return canceling
  }
}

func isPrepared(_ result: RoutePreparationResult) -> Bool {
  if case .prepared = result {
    return true
  }
  return false
}

func isCommitted(_ result: RouteCommitResult) -> Bool {
  if case .committed = result {
    return true
  }
  return false
}

func isUnchanged(_ result: RouteCommitResult) -> Bool {
  if case .unchanged = result {
    return true
  }
  return false
}

func makeRouteController(
  system: FakeFrameSource,
  microphone: FakeFrameSource?,
  state: MicrophoneAuthorizationState = .authorized
) -> (AudioRouteController, FakeMicrophoneAuthorizer) {
  let authorizer = FakeMicrophoneAuthorizer(state: state)
  var sources: [RecordingTrackRole: any AudioFrameSource] = [.system: system]
  if let microphone {
    sources[.microphone] = microphone
  }
  return (AudioRouteController(authorizer: authorizer, sources: sources), authorizer)
}

// MARK: - Route tests

@Test func prepareReturnsTokenAndCommitRequiresIt() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let preparation = await controller.prepare(.system)
  #expect(isPrepared(preparation.result))
  #expect(preparation.generation != nil)
  #expect(system.startCount == 1)

  let event = RouteEvent(atSample: 480, mode: .system, deviceID: nil)
  let stale = await controller.commit(event, preparationID: UUID())
  #expect(isUnchanged(stale))
  #expect(system.commitCount == 0)

  let committed = await controller.commit(event, preparationID: preparation.preparationID)
  #expect(committed == .committed(atSample: 480))
  #expect(await controller.currentGeneration(for: .system) != nil)
}

@Test func repeatedCommitAfterSuccessIsUnchanged() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let preparation = await controller.prepare(.system)
  let event = RouteEvent(atSample: 0, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(event, preparationID: preparation.preparationID)))

  let repeated = await controller.commit(event, preparationID: preparation.preparationID)

  #expect(isUnchanged(repeated))
}

@Test func supersededPreparationRollsBackOnlyNewSource() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let first = await controller.prepare(.system)
  let second = await controller.prepare(.system)

  #expect(system.startCount == 2)
  #expect(system.stopCount == 1)
  let event = RouteEvent(atSample: 100, mode: .system, deviceID: nil)
  #expect(isUnchanged(await controller.commit(event, preparationID: first.preparationID)))
  #expect(isCommitted(await controller.commit(event, preparationID: second.preparationID)))
}

@Test func concurrentCommitsApplyExactlyOnce() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let preparation = await controller.prepare(.system)
  let event = RouteEvent(atSample: 960, mode: .system, deviceID: nil)

  async let first = controller.commit(event, preparationID: preparation.preparationID)
  async let second = controller.commit(event, preparationID: preparation.preparationID)
  let results = await [first, second]

  #expect(results.filter(isCommitted).count == 1)
  #expect(results.filter(isUnchanged).count == 1)
  #expect(system.commitCount == 1)
}

@Test func failedCommitKeepsOldGenerationAndData() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let first = await controller.prepare(.system)
  let event = RouteEvent(atSample: 0, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(event, preparationID: first.preparationID)))
  let oldValue = await controller.currentGeneration(for: .system)
  let old = try #require(oldValue)
  let samples: [Float] = [0.25, 0.5]
  samples.withUnsafeBufferPointer { buffer in
    _ = old.ringBuffer.write(interleaved: buffer, frameCount: 1, hostTime: 1_000)
  }

  system.commitAccepts = false
  let preparation = await controller.prepareDeviceChange(
    AudioDeviceChangeEvent(
      role: .system,
      deviceID: "opaque-output",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )
  #expect(isPrepared(preparation.result))
  let failed = await controller.commit(event, preparationID: preparation.preparationID)

  #expect(isUnchanged(failed))
  let currentValue = await controller.currentGeneration(for: .system)
  let current = try #require(currentValue)
  #expect(current.id == old.id)
  #expect(old.ringBuffer.isClosedAndEmpty == false)
  #expect(old.ringBuffer.stats.acceptedFrames == 1)
}

@Test func commitFailureRollsBackOnlyNewRoleAndKeepsOldSourceHealthy() async throws {
  let system = try FakeFrameSource(role: .system)
  let microphone = try FakeFrameSource(role: .microphone)
  let (controller, _) = makeRouteController(system: system, microphone: microphone)
  let first = await controller.prepare(.system)
  let event = RouteEvent(atSample: 0, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(event, preparationID: first.preparationID)))
  let oldSystemValue = await controller.currentGeneration(for: .system)
  let oldSystem = try #require(oldSystemValue)
  microphone.commitAccepts = false

  let preparation = await controller.prepare(.systemAndMicrophone)
  #expect(isPrepared(preparation.result))
  let bothEvent = RouteEvent(atSample: 1_024, mode: .systemAndMicrophone, deviceID: nil)
  let failed = await controller.commit(bothEvent, preparationID: preparation.preparationID)

  #expect(isUnchanged(failed))
  #expect(microphone.stopCount == 1)
  #expect(system.stopCount == 0)
  #expect(system.isStarted)
  #expect(await controller.currentGeneration(for: .microphone) == nil)
  let currentSystemValue = await controller.currentGeneration(for: .system)
  let currentSystem = try #require(currentSystemValue)
  #expect(currentSystem.id == oldSystem.id)
  #expect(oldSystem.ringBuffer.isClosedAndEmpty == false)
}

@Test func deniedMicrophoneDoesNotAffectSystem() async throws {
  let system = try FakeFrameSource(role: .system)
  let microphone = try FakeFrameSource(role: .microphone)
  let (controller, authorizer) = makeRouteController(
    system: system,
    microphone: microphone,
    state: .denied
  )

  let preparation = await controller.prepare(.systemAndMicrophone)
  #expect(isPrepared(preparation.result))
  #expect(microphone.startCount == 0)
  #expect(authorizer.requestCount == 0)

  #expect(preparation.effectiveMode == .system)
  #expect(preparation.effectiveRoles == [.system])
  let event = RouteEvent(atSample: 240, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(event, preparationID: preparation.preparationID)))
  #expect(await controller.currentGeneration(for: .system) != nil)
  #expect(await controller.currentGeneration(for: .microphone) == nil)
}

@Test func microphoneOnlyDenialFailsPreparationWithoutPrompting() async throws {
  let system = try FakeFrameSource(role: .system)
  let microphone = try FakeFrameSource(role: .microphone)
  let (controller, authorizer) = makeRouteController(
    system: system,
    microphone: microphone,
    state: .unknown
  )

  let preparation = await controller.prepare(.microphone)

  guard case .unchangedOnFailure = preparation.result else {
    Issue.record("expected preparation failure")
    return
  }
  #expect(authorizer.requestCount == 0)
  #expect(microphone.startCount == 0)
}

@Test func deviceChangeRetiresOldGenerationExactlyOnce() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let first = await controller.prepare(.system)
  let event = RouteEvent(atSample: 0, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(event, preparationID: first.preparationID)))
  let oldValue = await controller.currentGeneration(for: .system)
  let old = try #require(oldValue)

  let preparation = await controller.prepareDeviceChange(
    AudioDeviceChangeEvent(
      role: .system,
      deviceID: "opaque-output",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )
  #expect(isPrepared(preparation.result))
  #expect(isCommitted(await controller.commit(event, preparationID: preparation.preparationID)))
  let newValue = await controller.currentGeneration(for: .system)
  let new = try #require(newValue)
  #expect(new.id != old.id)

  let retired = await controller.takeRetiredGenerations()
  #expect(retired.count == 1)
  #expect(retired.first?.id == old.id)
  #expect(await controller.takeRetiredGenerations().isEmpty)
  #expect(old.ringBuffer.isClosedAndEmpty == true)
}

@Test func supersededDevicePreparationCancelsReplacement() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let first = await controller.prepare(.system)
  let event = RouteEvent(atSample: 0, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(event, preparationID: first.preparationID)))
  let old = await controller.currentGeneration(for: .system)

  let device = await controller.prepareDeviceChange(
    AudioDeviceChangeEvent(
      role: .system,
      deviceID: "opaque-output",
      format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
    )
  )
  #expect(isPrepared(device.result))
  let fresh = await controller.prepare(.system)

  #expect(system.cancelCount == 1)
  #expect(isUnchanged(await controller.commit(event, preparationID: device.preparationID)))
  #expect(isCommitted(await controller.commit(event, preparationID: fresh.preparationID)))
  let current = await controller.currentGeneration(for: .system)
  #expect(current?.id == old?.id)
}

@Test func closedRingIsNotReusedAfterDisableAndReEnable() async throws {
  let system = try FakeFrameSource(role: .system)
  let (controller, _) = makeRouteController(system: system, microphone: nil)
  let first = await controller.prepare(.system)
  let onEvent = RouteEvent(atSample: 0, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(onEvent, preparationID: first.preparationID)))
  let oldValue = await controller.currentGeneration(for: .system)
  let old = try #require(oldValue)

  let none = await controller.prepare(.none)
  let offEvent = RouteEvent(atSample: 4_800, mode: .none, deviceID: nil)
  #expect(isCommitted(await controller.commit(offEvent, preparationID: none.preparationID)))
  #expect(await controller.currentGeneration(for: .system) == nil)
  #expect(system.stopCount == 1)

  let fresh = await controller.prepare(.system)
  let onAgain = RouteEvent(atSample: 9_600, mode: .system, deviceID: nil)
  #expect(isCommitted(await controller.commit(onAgain, preparationID: fresh.preparationID)))
  let newValue = await controller.currentGeneration(for: .system)
  let new = try #require(newValue)

  #expect(new.id != old.id)
  #expect(new.ringBuffer !== old.ringBuffer)
  #expect(old.ringBuffer.isClosedAndEmpty == true)
  #expect(new.ringBuffer.isClosedAndEmpty == false)
}

@Test func systemAndMicrophoneUseIndependentRoleRings() async throws {
  let system = try FakeFrameSource(role: .system)
  let microphone = try FakeFrameSource(role: .microphone)
  let (controller, _) = makeRouteController(system: system, microphone: microphone)
  let preparation = await controller.prepare(.systemAndMicrophone)
  let event = RouteEvent(atSample: 0, mode: .systemAndMicrophone, deviceID: nil)
  #expect(isCommitted(await controller.commit(event, preparationID: preparation.preparationID)))

  let systemGenerationValue = await controller.currentGeneration(for: .system)
  let systemGeneration = try #require(systemGenerationValue)
  let microphoneGenerationValue = await controller.currentGeneration(for: .microphone)
  let microphoneGeneration = try #require(microphoneGenerationValue)

  #expect(systemGeneration.role == .system)
  #expect(microphoneGeneration.role == .microphone)
  #expect(systemGeneration.ringBuffer !== microphoneGeneration.ringBuffer)
  #expect(systemGeneration.id != microphoneGeneration.id)
  #expect(system.stopCount == 0)
  #expect(microphone.stopCount == 0)
}
