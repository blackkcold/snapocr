import CaptureCore
import Foundation
import SharedKit

/// The reservation facts for one audio start.
///
/// Created synchronously before the first suspension point, so a second start can
/// never pass the same idle-state checks.
private struct AudioStartBooking {
    let identity: RecordingRequestIdentity
    let owner: UUID
}

/// The settled stop result plus the reason that actually started the stop.
private struct AudioStopSettlement {
    let settlement: RecordingSettlement
    let reason: RecordingSettlementReason
}

/// Everything one audio start needs to build its pipeline.
private struct AudioStartContext {
    let configuration: AudioRecordingConfiguration
    let roots: RecordingPipelineRoots
    let isCustomDestination: Bool
    let expectedVolumeUUID: String?
    let identity: RecordingRequestIdentity
    let owner: UUID
}

/// Audio pipeline start, stop, retirement, and routing for the recording session.
extension RecordingSessionController {
    /// Starts the audio pipeline after the app has resolved the required system permission.
    /// This method never requests microphone permission itself.
    ///
    /// - Parameters:
    ///   - configuration: The source, layout, and bitrate snapshot taken at invocation.
    ///   - roots: The destination snapshot taken at invocation.
    ///   - isCustomDestination: Whether the user picked the destination. A custom
    ///     external folder is validated at its exact path and never falls back.
    ///   - request: The identity created by ``beginAudioRequest(requiresMicrophonePermission:)`` before the
    ///     permission prompt. `nil` creates a fresh identity for legacy callers.
    func startAudio(
        _ configuration: AudioRecordingConfiguration,
        roots: RecordingPipelineRoots,
        isCustomDestination: Bool,
        expectedVolumeUUID: String? = nil,
        request: RecordingRequestIdentity? = nil
    ) async throws {
        let booking = try beginAudioStart(request: request)
        let identity = booking.identity
        let owner = booking.owner
        let generation = identity.generation

        resetAudioState(for: configuration, identity: identity)
        // The destination check is a visible preparation step, not part of the
        // "starting" spinner. Report it before the probe and only enter
        // `.starting` once the pipeline factory is about to run.
        preparationPhase = .verifyingDestination
        updatePreparationPhase(.verifyingDestination)
        startAudioStartupWatchdog(generation: generation, owner: owner)

        await closeAudioPreview()
        guard generation == sessionGeneration, audioResourceOwner == owner else {
            releaseAudioResourceOwner(owner)
            throw RecordingReadinessError.supersededStart
        }
        audioProgressTask?.cancel()
        audioProgressTask = nil
        previewReadinessTask?.cancel()
        previewReadinessTask = nil

        let pipeline = try await makeAudioPipeline(
            AudioStartContext(
                configuration: configuration,
                roots: roots,
                isCustomDestination: isCustomDestination,
                expectedVolumeUUID: expectedVolumeUUID,
                identity: identity,
                owner: owner
            )
        )
        try await adoptAudioPipeline(pipeline, configuration: configuration, identity: identity, owner: owner)
    }

    /// Runs every state check and reserves the start slot before any mutation.
    ///
    /// A rejected start therefore leaves the current request and UI untouched.
    private func beginAudioStart(request: RecordingRequestIdentity?) throws -> AudioStartBooking {
        guard !isAudioSessionActive, !hasPendingBackgroundFinalization else {
            throw RecordingPipelineError.alreadyStarted
        }
        guard !screenStartOwnership.blocksNewStart, screenCleanupTask == nil else {
            throw RecordingPipelineError.alreadyStarted
        }
        // Reserve the start slot synchronously, before any suspension point, so a
        // second start cannot pass the same idle-state checks. The resource owner
        // is separate from the UI terminal state: it outlives an early UI settle
        // until the real setup/start/stop operation has drained.
        guard audioResourceOwner == nil, audioStartReservation == nil else {
            throw RecordingPipelineError.alreadyStarted
        }

        let identity = try resolveAudioStartIdentity(request)
        let owner = UUID()
        audioResourceOwner = owner
        audioStartReservation = owner
        return AudioStartBooking(identity: identity, owner: owner)
    }

    /// Returns the request identity that owns this start, or creates a fresh one.
    private func resolveAudioStartIdentity(
        _ request: RecordingRequestIdentity?
    ) throws -> RecordingRequestIdentity {
        if let request {
            // The permission prompt may return after a cancel or a newer request.
            // Only a request that still owns the UI may create a pipeline.
            guard request.kind == .audio,
                currentRequest == request,
                request.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
                status == .selectingSource
            else { throw RecordingReadinessError.supersededStart }
            return request
        }
        guard status == .idle else { throw RecordingPipelineError.alreadyStarted }
        let identity = RecordingRequestIdentity(kind: .audio)
        sessionGeneration = identity.generation
        currentRequest = identity
        activeRecordingKind = .audio
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        preparationPhase = .checkingPermission
        phaseStartedAt = clock.now
        RecordingSignposts.emit(.preparing, kind: .audio)
        return identity
    }

    /// Clears the previous audio session's state for a fresh pipeline.
    private func resetAudioState(
        for configuration: AudioRecordingConfiguration,
        identity: RecordingRequestIdentity
    ) {
        currentRequest = identity
        activeRecordingKind = .audio
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        audioStateMachine = RecordingAudioSessionStateMachine()
        audioStateMachine.apply(.begin)
        audioConfiguration = configuration
        audioSessionID = UUID()
        audioPipeline = nil
        audioPipelineStarted = false
        audioStopRequested = false
        lastAudioResult = nil
        audioProgress = nil
        audioCurrentMode = configuration.mode
        latestAudioOutputURL = nil
        audioHUDExpanded = false
        audioSilenceStartedAt = nil
        audioSilenceWarningShown = false
        audioSilenceWarningVisible = false
        panelHiddenByUser = false
    }

    /// Validates the destination and builds the pipeline, adopting neither on failure.
    private func makeAudioPipeline(
        _ context: AudioStartContext
    ) async throws -> RecordingSessionPipeline {
        let identity = context.identity
        let owner = context.owner
        let pipeline: RecordingSessionPipeline
        do {
            // Location only: no capacity read here. The pipeline's preflight is
            // the single capacity decision for this start.
            try await RecordingDestinationProbe.validateLocation(
                directory: context.roots.outputDirectory,
                isCustom: context.isCustomDestination,
                expectedVolumeUUID: context.expectedVolumeUUID
            )
            guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply else {
                throw RecordingReadinessError.supersededStart
            }
            startPhase = .startingAudioPipeline
            phaseStartedAt = clock.now
            updateStatus(.starting)
            RecordingSignposts.emit(.starting, kind: .audio)
            emitStartPhaseSignpost(kind: .audio)
            pipeline = try await audioPipelineFactory(
                context.configuration,
                context.roots,
                context.expectedVolumeUUID
            )
        } catch {
            cancelAudioStartBookkeeping()
            guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
                lastAudioResult == nil
            else {
                releaseAudioResourceOwner(owner)
                throw RecordingReadinessError.supersededStart
            }
            completeAudioSession(with: failedAudioResult(error))
            releaseAudioResourceOwner(owner)
            throw error
        }
        guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
            lastAudioResult == nil,
            audioResourceOwner == owner
        else {
            // The factory ran on its worker; a cancel, watchdog, or replacement
            // settled while it did. Never adopt or start a pipeline for a session
            // that has already settled.
            cancelAudioStartBookkeeping()
            releaseAudioResourceOwner(owner)
            throw RecordingReadinessError.supersededStart
        }
        return pipeline
    }

    /// Starts the pipeline and arms its supervisor ticket.
    private func adoptAudioPipeline(
        _ pipeline: RecordingSessionPipeline,
        configuration: AudioRecordingConfiguration,
        identity: RecordingRequestIdentity,
        owner: UUID
    ) async throws {
        audioPipeline = pipeline
        audioSessionID = pipeline.ledger.sessionID
        let task = Task { try await pipeline.start(configuration) }
        audioStartTask = task
        try await awaitAudioPipelineStart(task, identity: identity, owner: owner)
        cancelAudioStartBookkeeping()
        audioStartTask = nil
        guard identity.disposition(generation: sessionGeneration, holdsResource: true) == .apply,
            lastAudioResult == nil,
            audioResourceOwner == owner
        else {
            // A genuine late success must stop its own pipeline exactly once; the
            // owner stays reserved until that retirement drains.
            scheduleAudioRetirement(pipeline, owner: owner)
            throw RecordingReadinessError.supersededStart
        }
        await armAudioSettlement(pipeline, generation: identity.generation)
    }

    /// Waits for `pipeline.start` and classifies its failure without adopting it.
    private func awaitAudioPipelineStart(
        _ task: Task<Void, any Error>,
        identity: RecordingRequestIdentity,
        owner: UUID
    ) async throws {
        do {
            try await task.value
        } catch {
            cancelAudioStartBookkeeping()
            audioStartTask = nil
            guard identity.disposition(generation: sessionGeneration, holdsResource: false) == .apply,
                lastAudioResult == nil
            else {
                // The UI already settled (cancel, watchdog, bounded stop). The
                // failed start owns no live resources, so release the owner and
                // suppress a second visible failure.
                releaseAudioResourceOwner(owner)
                throw RecordingReadinessError.supersededStart
            }
            // A failed start never keeps a half-created pipeline reference.
            if !audioPipelineStarted { audioPipeline = nil }
            completeAudioSession(with: failedAudioResult(error))
            releaseAudioResourceOwner(owner)
            throw error
        }
    }

    /// Arms the first-sample deadline before the HUD presents `.starting`.
    private func armAudioSettlement(
        _ pipeline: RecordingSessionPipeline,
        generation: UUID
    ) async {
        // Arm before presenting: the first-sample deadline must already exist when
        // the HUD shows `.starting`, so a stalled main thread cannot skip it.
        let deadline = firstSampleDeadlineOverride ?? RecordingReadiness.firstAudioSampleDeadline
        let readiness: RecordingSettlementSupervisor.Readiness =
            suppressFirstSampleReadiness
            ? .poll { .waiting }
            : .audioProgress(pipeline.makeProgressStream())
        screenSettlementTicket = nil
        audioSettlementTicket = await settlementSupervisor.arm(
            generation: generation,
            kind: .audio,
            deadline: deadline,
            promotionDeadline: RecordingReadiness.firstAudioPresentationDeadline,
            livenessDeadline: RecordingReadiness.recordingLivenessDeadline,
            readiness: readiness,
            stop: { [pipeline] in
                // `RecordingSessionPipeline.stop()` is idempotent and actor-isolated;
                // this closure never touches the main actor.
                .audio(await pipeline.stop())
            }
        )
        markAudioPipelineStarted()
        startAudioProgressMonitoring(for: pipeline, generation: generation)
        if audioStopRequested {
            _ = await stopAudio()
        }
    }

    /// Cancels the watchdog and drops the reservation without releasing the owner.
    private func cancelAudioStartBookkeeping() {
        audioStartWatchdogTask?.cancel()
        audioStartWatchdogTask = nil
        audioStartReservation = nil
    }

    /// Bounds the platform startup (factory plus `pipeline.start`) independently of
    /// the first-sample readiness timer.
    ///
    /// If it fires, the UI receives a visible failure but the start keeps running;
    /// a later success stops its own pipeline through `scheduleAudioRetirement`.
    private func startAudioStartupWatchdog(generation: UUID, owner: UUID) {
        audioStartWatchdogTask?.cancel()
        audioStartWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: RecordingReadiness.platformStartDeadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                generation == self.sessionGeneration,
                self.audioResourceOwner == owner,
                self.audioStartReservation == owner,
                self.lastAudioResult == nil,
                self.audioStateMachine.state == .starting
            else { return }
            self.outcomeState.markCaptureAttempted()
            self.completeAudioSession(
                with: self.failedAudioResult(RecordingReadinessError.startTimedOut)
            )
        }
    }

    /// Stops resources for an operation whose UI has already settled.
    ///
    /// At most one retirement runs at a time. The resource owner is released only
    /// after the pipeline has drained, so no new capture can overlap it.
    private func scheduleAudioRetirement(_ pipeline: RecordingSessionPipeline, owner: UUID) {
        guard audioRetireTask == nil else { return }
        audioRetireTask = Task { @MainActor [weak self] in
            let result = await pipeline.stop()
            guard let self else { return }
            if Self.audioResultWasSaved(result) {
                self.registerRecoveryMaterials(sessionID: result.sessionID, pipeline: pipeline)
            }
            self.releaseAudioResourceOwner(owner)
        }
    }

    func releaseAudioResourceOwner(_ owner: UUID) {
        guard audioResourceOwner == owner else { return }
        audioResourceOwner = nil
        audioStartReservation = nil
        audioRetireTask = nil
    }

    /// Stops capture idempotently and returns only after T9 has drained tail and seal work.
    ///
    /// Concurrent callers join one in-flight stop. A hanging pipeline start is
    /// bounded so a cancel or stop can still produce a UI result. The tail/seal
    /// save itself is not bounded: a legitimately long save keeps running and is
    /// reported by its real result.
    func stopAudio() async -> AudioRecordingResult {
        if let audioStopJoinTask { return await audioStopJoinTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return AudioRecordingResult(
                    sessionID: UUID(),
                    kind: .audio,
                    layout: .mixed,
                    segmentCount: 0,
                    droppedRanges: [],
                    checkpointAge: 0,
                    failure: "recording session was released"
                )
            }
            return await self.performAudioStop()
        }
        audioStopJoinTask = task
        let result = await task.value
        audioStopJoinTask = nil
        return result
    }

    private func performAudioStop() async -> AudioRecordingResult {
        // A settled session that is still retiring its own pipeline owns the
        // resources; do not start a second stop against it.
        if audioRetireTask != nil {
            return lastAudioResult ?? makeAudioResult(failure: "recording is still stopping")
        }
        if pendingRecoverySessionIDs.contains(audioSessionID ?? UUID()), let lastAudioResult {
            return lastAudioResult
        }
        if !isAudioSessionActive && !hasPendingBackgroundFinalization {
            return lastAudioResult ?? makeAudioResult(failure: "recording pipeline is not active")
        }

        let generation = sessionGeneration
        let owner = audioResourceOwner
        let sessionID = audioSessionID
        if let early = await awaitAudioStartBeforeStop(generation: generation, sessionID: sessionID) {
            return early
        }

        guard let pipeline = audioPipeline else {
            let result = lastAudioResult ?? makeAudioResult(failure: "recording pipeline is unavailable")
            completeAudioSession(with: result)
            return result
        }

        beginAudioFinalization()
        await beginPreviewReadinessMonitoring(for: pipeline)

        // The supervisor owns the single stop. A deadline that already started it
        // returns the same settlement instead of stopping twice, and the reason it
        // reports is the one that actually started the stop.
        guard let stopped = await resolveAudioStopSettlement(pipeline) else {
            return lastAudioResult ?? makeAudioResult(failure: "recording pipeline is unavailable")
        }
        await applyAudioSettlement(
            stopped.settlement,
            generation: generation,
            reason: stopped.reason,
            owner: owner,
            pipeline: pipeline
        )
        return lastAudioResult ?? makeAudioResult(failure: "recording pipeline is unavailable")
    }

    /// Joins an in-flight `pipeline.start` before stopping it.
    ///
    /// - Returns: An early result the stop must return, or `nil` to continue.
    private func awaitAudioStartBeforeStop(
        generation: UUID,
        sessionID: UUID?
    ) async -> AudioRecordingResult? {
        guard let audioStartTask else { return nil }
        audioStopRequested = true
        audioStateMachine.apply(.stopRequested)
        updateStatus(audioStateMachine.legacyStatus)
        let started = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
            do {
                try await audioStartTask.value
                return true
            } catch {
                return false
            }
        }
        guard generation == sessionGeneration, sessionID == audioSessionID else {
            return lastAudioResult ?? makeAudioResult(failure: "recording pipeline was replaced")
        }
        guard let started else {
            let result = failedAudioResult(RecordingReadinessError.uiWaitTimedOut)
            completeAudioSession(with: result)
            return result
        }
        guard started else {
            if let lastAudioResult { return lastAudioResult }
            let result = failedAudioResult(
                RecordingReadinessError.cancelledWhileStarting
            )
            completeAudioSession(with: result)
            return result
        }
        if let lastAudioResult { return lastAudioResult }
        markAudioPipelineStarted()
        return nil
    }

    /// Moves the audio state machine into its finalizing stop before the save.
    private func beginAudioFinalization() {
        audioStopRequested = true
        audioStateMachine.apply(.stopRequested)
        audioStateMachine.beginFinalization()
        updateStatus(audioStateMachine.legacyStatus)
        if let kind = currentRecordingKind { RecordingSignposts.emit(.saving, kind: kind) }
    }

    /// Settles through the supervisor ticket, or through the pipeline's own stop.
    private func resolveAudioStopSettlement(
        _ pipeline: RecordingSessionPipeline
    ) async -> AudioStopSettlement? {
        var settlement: RecordingSettlement?
        var settledReason: RecordingSettlementReason = .requested
        if let ticket = audioSettlementTicket {
            settlement = await settlementSupervisor.settle(ticket: ticket, reason: .requested)
            if let actual = await settlementSupervisor.settledReason(for: ticket) {
                settledReason = actual
            }
            audioSettlementTicket = nil
        }
        if settlement == nil {
            // No ticket owns this generation; the pipeline's own idempotent stop is
            // the only remaining stop for it.
            settlement = .audio(await pipeline.stop())
        }
        guard let settlement else { return nil }
        return AudioStopSettlement(settlement: settlement, reason: settledReason)
    }

    func applyRoute(_ event: RouteEvent) async -> RouteCommitResult {
        guard let audioPipeline else {
            return .unchanged(reason: "recording pipeline is not active")
        }
        let result = await audioPipeline.applyRoute(event)
        if case .committed = result { audioCurrentMode = event.mode }
        return result
    }

    func makeAudioProgressStream() -> AsyncStream<RecordingProgress> {
        guard let audioPipeline else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return audioPipeline.makeProgressStream()
    }

    func waitForBackgroundFinalization() async -> RecordingSessionTerminalOutcome {
        if let audioStopJoinTask {
            _ = await audioStopJoinTask.value
            return outcomeState.terminalOutcome ?? .failed
        }
        if let audioRetireTask {
            // The settled session is still stopping its own late-started pipeline.
            _ = await audioRetireTask.value
            return outcomeState.terminalOutcome ?? .failed
        }
        if audioStopRequested {
            _ = await stopAudio()
            return outcomeState.terminalOutcome ?? .failed
        }
        if isAudioSessionActive { return .failed }
        return outcomeState.terminalOutcome ?? .noActiveSession
    }

    func pipelineRoots(for directory: URL) -> RecordingPipelineRoots {
        let outputDirectory = directory.standardizedFileURL
        let sessionsDirectory = outputDirectory.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        return RecordingPipelineRoots(
            sessionRoot: outputDirectory,
            indexURL: sessionsDirectory.appendingPathComponent("recording-index.json"),
            outputDirectory: outputDirectory
        )
    }

    private func markAudioPipelineStarted() {
        guard !audioPipelineStarted else { return }
        audioPipelineStarted = true
        outcomeState.markCaptureAttempted()
        guard !audioStopRequested else { return }
        startPhase = .awaitingFirstAudioSample
        phaseStartedAt = clock.now
        emitStartPhaseSignpost(kind: .audio)
        // `updateStatus` is the only entry point that presents: the audio branch of
        // `.starting` creates and shows the panel, so a second present here would
        // enqueue the same state again in the same turn.
        updateStatus(.starting)
    }
}
