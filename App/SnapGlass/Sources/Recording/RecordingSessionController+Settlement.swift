import CaptureCore
import Foundation
import SharedKit

/// Settlement consumption and the single terminal write for the recording session.
extension RecordingSessionController {
    /// Monotonic-clock supervisor facts, used by the agent test report.
    func settlementDiagnostics() async -> RecordingSettlementSupervisor.Diagnostics {
        await settlementSupervisor.diagnostics()
    }

    /// Consumes one supervisor event on the main actor.
    func handleSettlementEvent(_ event: RecordingSettlementSupervisor.Event) async {
        switch event {
        case let .mediaStarted(generation, kind):
            await handleMediaStarted(generation: generation, kind: kind)
        case let .settled(generation, kind, settlement, reason):
            await handleSettled(generation: generation, kind: kind, settlement: settlement, reason: reason)
        }
    }

    /// Applies a promotion event, then confirms it on a later turn.
    private func handleMediaStarted(generation: UUID, kind: RecordingKind) async {
        switch kind {
        case .audio:
            handleAudioReadiness(generation: generation)
        case .screen:
            await handleScreenFirstFrame(generation: generation)
        }
        schedulePresentationAcknowledgement(generation: generation)
    }

    /// Confirms that a promoted state was really presented.
    ///
    /// The acknowledgement must represent a main actor that is still alive after
    /// the promotion turn, not merely one that reached the state change: the
    /// panel's first draw of the promoted state can happen after this turn (the
    /// HUD no longer displays synchronously). A later turn that never runs is
    /// exactly the frozen-interface case the supervisor must catch. The same
    /// applies to the screen promotion, which is a plain state update but still
    /// runs on the main actor; the supervisor then stops and saves the session
    /// itself instead of capturing unbounded.
    private func schedulePresentationAcknowledgement(generation: UUID) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard let self else { return }
            await self.settlementSupervisor.acknowledgePresentation(
                generation: generation
            )
        }
    }

    /// Applies one settled stop to the UI.
    private func handleSettled(
        generation: UUID,
        kind: RecordingKind,
        settlement: RecordingSettlement,
        reason: RecordingSettlementReason
    ) async {
        switch kind {
        case .audio:
            await applyAudioSettlement(
                settlement,
                generation: generation,
                reason: reason,
                owner: nil,
                pipeline: nil
            )
        case .screen:
            let engine = self.engine
            let materialRoot = await screenPipelineAdapter?.materialRoot()
            await applyScreenSettlement(
                settlement,
                generation: generation,
                reason: reason,
                materialRoot: materialRoot,
                engine: engine
            )
        }
    }

    /// Applies one audio settlement on the main actor.
    ///
    /// Called both by the awaiting stop path (which needs its return value) and by
    /// the event consumer (which covers a deadline stop nobody awaited). The first
    /// call applies it; every later report of the same generation is a no-op.
    ///
    /// - Parameters:
    ///   - settlement: The settled stop result.
    ///   - generation: The session generation the settlement belongs to.
    ///   - reason: Whether a request or the deadline produced it.
    ///   - owner: The resource owner to release once the pipeline has drained.
    ///   - pipeline: The pipeline the settlement came from, for the output URL.
    func applyAudioSettlement(
        _ settlement: RecordingSettlement,
        generation: UUID,
        reason: RecordingSettlementReason,
        owner: UUID?,
        pipeline explicitPipeline: RecordingSessionPipeline?
    ) async {
        guard markSettlementApplied(generation) else { return }
        let pipeline = explicitPipeline ?? audioPipeline
        let outputURL = await pipeline?.latestPublishedFileURL()
        releaseAudioOwnerAfterSettlement(owner, generation: generation)
        await previewReadinessTask?.value

        guard generation == sessionGeneration, lastAudioResult == nil else {
            // The UI already settled this session (cancel, replacement, or a stop
            // that ran twice). Keep any real material reachable for recovery and
            // never touch the newer session.
            if case let .audio(result) = settlement, Self.audioResultWasSaved(result),
                let pipeline
            {
                registerRecoveryMaterials(sessionID: result.sessionID, pipeline: pipeline)
            }
            return
        }
        finishAudioSettlement(settlement, reason: reason, outputURL: outputURL)
    }

    /// Releases the audio resource owner once the pipeline has drained.
    private func releaseAudioOwnerAfterSettlement(_ owner: UUID?, generation: UUID) {
        // A deadline stop has no awaiting caller, so it releases the owner the
        // session still holds; a newer generation's UI is never touched.
        if let owner {
            releaseAudioResourceOwner(owner)
        } else if generation == sessionGeneration, let currentOwner = audioResourceOwner {
            releaseAudioResourceOwner(currentOwner)
        }
    }

    /// Moves a supervisor-initiated stop into finalizing, then presents its result.
    private func finishAudioSettlement(
        _ settlement: RecordingSettlement,
        reason: RecordingSettlementReason,
        outputURL: URL?
    ) {
        // A deadline or promotion-stall stop never passed through the requested-stop
        // path, so move the state machine to finalizing here. A promotion stall can
        // arrive while the state machine already reported `.recording` (the main
        // actor processed the promotion but then stopped responding), so both live
        // states must be able to finish; without this the session would stay in
        // `.recording`, refuse the next recording, and never show its result.
        if reason != .requested,
            audioStateMachine.state == .starting || audioStateMachine.state == .recording
        {
            audioStateMachine.apply(.stopRequested)
            audioStateMachine.beginFinalization()
        }

        switch settlement {
        case let .audio(result):
            completeAudioSettlement(result, reason: reason, outputURL: outputURL)
        case let .failed(_, message):
            completeAudioSession(with: makeAudioResult(failure: message))
        case .screen:
            completeAudioSession(
                with: makeAudioResult(failure: "the audio session returned a screen result")
            )
        }
    }

    /// Presents one settled audio result with the wording its reason requires.
    private func completeAudioSettlement(
        _ result: AudioRecordingResult,
        reason: RecordingSettlementReason,
        outputURL: URL?
    ) {
        if reason == .deadline, !Self.audioResultWasSaved(result) {
            completeAudioSession(
                with: Self.audioResult(
                    result,
                    failure: AppLocalization.recordingErrorDescription(
                        RecordingReadinessError.noAudioSamples
                    )
                )
            )
            return
        }
        if reason == .promotionStalled, !Self.audioResultWasSaved(result) {
            completeAudioSession(
                with: Self.audioResult(
                    result,
                    failure: AppLocalization.string(
                        // swiftlint:disable:next line_length
                        "The recording stopped because the interface stopped responding before any audio could be saved."
                    )
                ),
                errorClass: .timeout
            )
            return
        }
        if reason == .promotionStalled {
            onMessage?(
                AppLocalization.string(
                    // swiftlint:disable:next line_length
                    "The recording stopped because the interface stopped responding. Audio captured up to that point was saved."
                ),
                .info
            )
        }
        completeAudioSession(with: result, outputURL: outputURL)
    }

    /// The single idempotent terminal settlement shared by audio and screen paths.
    ///
    /// - Parameters:
    ///   - wasSaved: Whether published media is durable.
    ///   - errorClass: Optional privacy-safe failure class for the signpost only.
    /// - Returns: `true` only for the call that wrote the outcome.
    @discardableResult
    func settleTerminal(
        wasSaved: Bool,
        errorClass: RecordingDiagnosticErrorClass? = nil
    ) -> Bool {
        guard outcomeState.terminalOutcome == nil else { return false }
        let kind = activeRecordingKind
        outcomeState.finishSession(wasSaved: wasSaved)
        guard let kind, let outcome = outcomeState.terminalOutcome else { return true }
        let elapsed = phaseElapsedMilliseconds()
        let phase: RecordingPhase
        switch outcome {
        case .saved:
            phase = .finished
        case .failed:
            phase = .failed
        case .noActiveSession:
            phase = .cancelled
        }
        RecordingSignposts.emit(
            phase,
            kind: kind,
            elapsedMilliseconds: elapsed,
            errorClass: errorClass
        )
        announcePhase(phase, kind: kind)
        return true
    }
}
