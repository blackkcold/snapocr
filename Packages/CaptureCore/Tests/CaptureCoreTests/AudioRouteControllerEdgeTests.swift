import Foundation
import Testing

@testable import CaptureCore

// MARK: - External stop and effective route

@Test func commitAfterExternalStopIsUnchanged() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let preparation = await controller.prepare(.system)
    await system.stop()

    let result = await controller.commit(
        RouteEvent(atSample: 0, mode: .system, deviceID: nil),
        preparationID: preparation.preparationID
    )

    #expect(isUnchanged(result))
    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await controller.takeRetiredGenerations().isEmpty)
    #expect(system.startCount == 1)
}

@Test func prepareAfterExternalStopStartsFreshGeneration() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    let old = try #require(await controller.currentGeneration(for: .system))
    await system.stop()

    let second = await controller.prepare(.system)
    #expect(second.effectiveMode == .system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 100, mode: .system, deviceID: nil),
                preparationID: second.preparationID
            )
        )
    )
    let fresh = try #require(await controller.currentGeneration(for: .system))

    #expect(system.startCount == 2)
    #expect(fresh.id != old.id)
    #expect(fresh.ringBuffer !== old.ringBuffer)
    #expect(old.ringBuffer.isClosedAndEmpty == true)
}

@Test func inactiveDeviceChangeDoesNotSupersedeValidPending() async throws {
    let system = try FakeFrameSource(role: .system)
    let microphone = try FakeFrameSource(role: .microphone)
    let (controller, _) = makeRouteController(system: system, microphone: microphone)
    let pending = await controller.prepare(.system)

    let inactive = await controller.prepareDeviceChange(
        AudioDeviceChangeEvent(
            role: .microphone,
            deviceID: "opaque-input",
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 1)
        )
    )

    guard case .unchangedOnFailure = inactive.result else {
        Issue.record("expected inactive role failure")
        return
    }
    #expect(system.stopCount == 0)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: pending.preparationID
            )
        )
    )
}

@Test func invalidDeviceEventDoesNotSupersedeValidPending() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    let pending = await controller.prepare(.system)

    let invalid = await controller.prepareDeviceChange(
        AudioDeviceChangeEvent(
            role: .system,
            deviceID: "opaque-output",
            format: AudioSourceFormat(sampleRate: 0, channelCount: 2)
        )
    )

    guard case .unchangedOnFailure = invalid.result else {
        Issue.record("expected invalid format failure")
        return
    }
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 100, mode: .system, deviceID: nil),
                preparationID: pending.preparationID
            )
        )
    )
}

@Test func genericMicrophoneStartFailureFailsWholePreparation() async throws {
    let system = try FakeFrameSource(role: .system)
    let microphone = try FakeFrameSource(role: .microphone)
    microphone.startError = AudioSourceError.installFailed("tap install")
    let (controller, _) = makeRouteController(system: system, microphone: microphone)

    let preparation = await controller.prepare(.systemAndMicrophone)

    guard case .unchangedOnFailure = preparation.result else {
        Issue.record("expected generic microphone failure to fail preparation")
        return
    }
    #expect(system.startCount == 1)
    #expect(system.stopCount == 1)
    #expect(await controller.currentGeneration(for: .microphone) == nil)
}

@Test func authorizationFallbackExposesEffectiveSystemOnlyRoute() async throws {
    let system = try FakeFrameSource(role: .system)
    let microphone = try FakeFrameSource(role: .microphone)
    let (controller, authorizer) = makeRouteController(
        system: system,
        microphone: microphone,
        state: .denied
    )

    let preparation = await controller.prepare(.systemAndMicrophone)

    #expect(isPrepared(preparation.result))
    #expect(preparation.effectiveMode == .system)
    #expect(preparation.effectiveRoles == [.system])
    #expect(preparation.degradationReason != nil)
    #expect(authorizer.requestCount == 0)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: preparation.preparationID
            )
        )
    )
    #expect(await controller.currentEffectiveMode() == .system)
    #expect(await controller.currentEffectiveRoles() == [.system])
    #expect(await controller.currentGeneration(for: .microphone) == nil)
}

@Test func twoRolePartialCommitFailureRollsBackBothNewSources() async throws {
    let system = try FakeFrameSource(role: .system)
    let microphone = try FakeFrameSource(role: .microphone)
    microphone.commitAccepts = false
    let (controller, _) = makeRouteController(system: system, microphone: microphone)
    let preparation = await controller.prepare(.systemAndMicrophone)
    #expect(isPrepared(preparation.result))

    let result = await controller.commit(
        RouteEvent(atSample: 0, mode: .systemAndMicrophone, deviceID: nil),
        preparationID: preparation.preparationID
    )

    #expect(isUnchanged(result))
    #expect(system.stopCount == 1)
    #expect(microphone.stopCount == 1)
    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await controller.currentGeneration(for: .microphone) == nil)
    #expect(await controller.takeRetiredGenerations().isEmpty)
}

// MARK: - Validation and idempotence

@Test func negativeSampleAndModeMismatchAreUnchangedUntilCorrectCommit() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let preparation = await controller.prepare(.system)

    let negative = await controller.commit(
        RouteEvent(atSample: -1, mode: .system, deviceID: nil),
        preparationID: preparation.preparationID
    )
    let mismatch = await controller.commit(
        RouteEvent(atSample: 0, mode: .microphone, deviceID: nil),
        preparationID: preparation.preparationID
    )
    let correct = await controller.commit(
        RouteEvent(atSample: 0, mode: .system, deviceID: nil),
        preparationID: preparation.preparationID
    )

    #expect(isUnchanged(negative))
    #expect(isUnchanged(mismatch))
    #expect(isCommitted(correct))
}

@Test func preparingAnAlreadyActiveRoleDoesNotRestartIt() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )

    let second = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 100, mode: .system, deviceID: nil),
                preparationID: second.preparationID
            )
        )
    )

    #expect(system.startCount == 1)
    #expect(system.stopCount == 0)
}

@Test func retiredRingKeepsUnreadFramesDrainable() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    let old = try #require(await controller.currentGeneration(for: .system))
    let samples: [Float] = [0.75, -0.25]
    samples.withUnsafeBufferPointer { buffer in
        _ = old.ringBuffer.write(interleaved: buffer, frameCount: 1, hostTime: 500)
    }

    let preparation = await controller.prepareDeviceChange(
        AudioDeviceChangeEvent(
            role: .system,
            deviceID: "opaque-output",
            format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        )
    )
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 100, mode: .system, deviceID: nil),
                preparationID: preparation.preparationID
            )
        )
    )
    let retired = await controller.takeRetiredGenerations()
    #expect(retired.count == 1)
    let read = retired[0].ringBuffer.read(maxFrames: 8)
    #expect(read.block?.frameCount == 1)
    #expect(read.block?.channels[0] == [0.75])
    #expect(await controller.takeRetiredGenerations().isEmpty)
}

// MARK: - Cancellation

@Test func cancelledGateWaiterNeverRunsAfterRelease() async throws {
    let gate = AudioControlGate()
    await gate.acquire()
    let waiter = Task {
        let acquired = await gate.acquireCancellable()
        if acquired {
            await gate.release()
        }
        return acquired
    }
    try await Task.sleep(for: .milliseconds(20))
    waiter.cancel()
    await gate.release()

    #expect(await waiter.value == false)
}

@Test func prepareCancelledDuringStartRollsBackAndLeavesNoToken() async throws {
    let system = try FakeFrameSource(role: .system)
    system.startDelay = .milliseconds(200)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let task = Task { await controller.prepare(.system) }
    try await Task.sleep(for: .milliseconds(40))
    task.cancel()
    let preparation = await task.value

    guard case .unchangedOnFailure = preparation.result else {
        Issue.record("expected cancelled preparation failure")
        return
    }
    #expect(system.startCount == 1)
    #expect(system.stopCount == 1)
    #expect(await controller.currentGeneration(for: .system) == nil)
}

@Test func timedOutProducerIsWithheldUntilJoined() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    let old = try #require(await controller.currentGeneration(for: .system))
    system.producerJoined = false

    let preparation = await controller.prepareDeviceChange(
        AudioDeviceChangeEvent(
            role: .system,
            deviceID: "opaque-output",
            format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        )
    )
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 100, mode: .system, deviceID: nil),
                preparationID: preparation.preparationID
            )
        )
    )
    #expect(await controller.takeRetiredGenerations().isEmpty)

    system.producerJoined = true
    _ = await controller.currentEffectiveRoles()
    _ = await controller.prepare(.system)
    let retired = await controller.takeRetiredGenerations()
    #expect(retired.contains(where: { $0.id == old.id }))
}

@Test func noOpActivePreparationAfterExternalStopIsUnchanged() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    let noOp = await controller.prepare(.system)
    #expect(noOp.effectiveMode == .system)
    await system.stop()

    let committed = await controller.commit(
        RouteEvent(atSample: 100, mode: .system, deviceID: nil),
        preparationID: noOp.preparationID
    )

    #expect(isUnchanged(committed))
    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await controller.currentEffectiveRoles().isEmpty)
}

@Test func gettersPruneExternallyStoppedActiveRole() async throws {
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
    await system.stop()

    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await controller.currentEffectiveMode() == .none)
    #expect(await controller.currentEffectiveRoles().isEmpty)
}

@Test func timedOutStaleGenerationIsNotRetiredByPrepare() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    let old = try #require(await controller.currentGeneration(for: .system))
    system.producerJoined = false
    await system.stop()

    let refused = await controller.prepare(.system)
    guard case .unchangedOnFailure = refused.result else {
        Issue.record("expected start refusal while producer is unjoined")
        return
    }
    #expect(await controller.takeRetiredGenerations().isEmpty)

    system.producerJoined = true
    let retired = await controller.takeRetiredGenerations()
    #expect(retired.contains(where: { $0.id == old.id }))
}

@Test func cancellationAfterCurrentGenerationRollsBack() async throws {
    let system = try FakeFrameSource(role: .system)
    system.currentGenerationDelay = .milliseconds(200)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let task = Task { await controller.prepare(.system) }
    try await Task.sleep(for: .milliseconds(40))
    task.cancel()
    let preparation = await task.value

    guard case .unchangedOnFailure = preparation.result else {
        Issue.record("expected cancellation failure")
        return
    }
    #expect(system.startCount == 1)
    #expect(system.stopCount == 1)
    #expect(await controller.currentGeneration(for: .system) == nil)
}

@Test func failedCommitWithStoppedSourcePrunesHealth() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    system.commitAccepts = false
    system.stopOnRejectedCommit = true
    let preparation = await controller.prepareDeviceChange(
        AudioDeviceChangeEvent(
            role: .system,
            deviceID: "opaque-output",
            format: AudioSourceFormat(sampleRate: 44_100, channelCount: 1)
        )
    )
    let result = await controller.commit(
        RouteEvent(atSample: 100, mode: .system, deviceID: nil),
        preparationID: preparation.preparationID
    )

    guard case .unchanged(let reason) = result else {
        Issue.record("expected unhealthy commit failure")
        return
    }
    #expect(reason.contains("unhealthy"))
    #expect(reason.contains("system"))
    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await controller.currentEffectiveRoles().isEmpty)
}

@Test func cancelPendingPreparationInvalidatesTokenButKeepsActiveRoute() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let first = await controller.prepare(.system)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .system, deviceID: nil),
                preparationID: first.preparationID
            )
        )
    )
    let pending = await controller.prepare(.system)
    #expect(await controller.cancelPendingPreparation())
    #expect(
        isUnchanged(
            await controller.commit(
                RouteEvent(atSample: 100, mode: .system, deviceID: nil),
                preparationID: pending.preparationID
            )
        )
    )
    #expect(await controller.currentGeneration(for: .system) != nil)
    #expect(await controller.cancelPendingPreparation() == false)
}

@Test func shutdownIsIdempotentAndClearsEffectiveRoute() async throws {
    let system = try FakeFrameSource(role: .system)
    let microphone = try FakeFrameSource(role: .microphone)
    let (controller, _) = makeRouteController(system: system, microphone: microphone)
    let preparation = await controller.prepare(.systemAndMicrophone)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .systemAndMicrophone, deviceID: nil),
                preparationID: preparation.preparationID
            )
        )
    )

    #expect(await controller.shutdown())
    #expect(await controller.currentEffectiveMode() == .none)
    #expect(await controller.currentEffectiveRoles().isEmpty)
    #expect(await controller.shutdown())
    #expect(await controller.isShutdownComplete())
    #expect(system.stopCount == 1)
    #expect(microphone.stopCount == 1)
}

@Test func shutdownAfterPendingStartedSourceStopsItAndIsComplete() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    let preparation = await controller.prepare(.system)
    #expect(isPrepared(preparation.result))
    #expect(await controller.isShutdownComplete() == false)

    #expect(await controller.shutdown())
    #expect(system.stopCount == 1)
    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await controller.isShutdownComplete())
    let rejected = await controller.prepare(.system)
    guard case .unchangedOnFailure = rejected.result else {
        Issue.record("expected prepare rejection after shutdown")
        return
    }
}

@Test func shutdownCompleteRequiresShutdownRequest() async throws {
    let system = try FakeFrameSource(role: .system)
    let (controller, _) = makeRouteController(system: system, microphone: nil)
    #expect(await controller.isShutdownComplete() == false)
    #expect(await controller.shutdown())
    #expect(await controller.isShutdownComplete())
}

@Test func keptRoleStoppingDuringRemovedRoleTeardownFailsPublication() async throws {
    let system = try FakeFrameSource(role: .system)
    let microphone = try FakeFrameSource(role: .microphone)
    let (controller, _) = makeRouteController(system: system, microphone: microphone)
    let both = await controller.prepare(.systemAndMicrophone)
    #expect(
        isCommitted(
            await controller.commit(
                RouteEvent(atSample: 0, mode: .systemAndMicrophone, deviceID: nil),
                preparationID: both.preparationID
            )
        )
    )
    microphone.stopDelay = .milliseconds(200)
    microphone.onStop = {
        Task { await system.stop() }
    }
    let systemOnly = await controller.prepare(.system)
    #expect(isPrepared(systemOnly.result))

    let result = await controller.commit(
        RouteEvent(atSample: 100, mode: .system, deviceID: nil),
        preparationID: systemOnly.preparationID
    )

    #expect(isUnchanged(result))
    #expect(await controller.currentGeneration(for: .system) == nil)
    #expect(await controller.currentEffectiveRoles().isEmpty)
}
