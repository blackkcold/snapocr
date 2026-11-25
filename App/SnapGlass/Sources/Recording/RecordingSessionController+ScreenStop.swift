import AppKit
import CaptureCore
import Foundation
import SharedKit

/// Everything one screen settlement needs before it can be applied.
private struct ScreenSettlementContext {
    let intent: RecordingSessionController.ScreenStopIntent
    let stopReason: String?
    let reason: RecordingSettlementReason
    let generation: UUID
    let materialRoot: URL?
    let engine: ScreenRecordingEngine?
}

/// Screen finalization: the requested stop, the legacy single-file paths, the
/// settlement application, and the unconfirmed-stream retry.
extension RecordingSessionController {
    func finalizeRecording(reason: String?) async -> Bool {
        guard status == .recording, let engine else { return false }
        let generation = sessionGeneration
        guard screenStartOwnership.beginInitialStop(generation: generation) else { return false }
        monitoringTask?.cancel()
        monitoringTask = nil
        phaseStartedAt = clock.now
        updateStatus(.saving)
        if let kind = currentRecordingKind { RecordingSignposts.emit(.saving, kind: kind) }

        guard let adapter = screenPipelineAdapter else {
            return await finalizeLegacyRecording(reason: reason, engine: engine, generation: generation)
        }

        let materialRoot = await adapter.materialRoot()
        screenStopIntent = .recordingStop
        screenStopReason = reason
        screenSettlingGeneration = generation
        let ticket = screenSettlementTicket
        screenSettlementTicket = nil
        guard let ticket else {
            // Defensive: no supervisor ticket owns this start; seal the files with
            // the adapter's own single stop.
            return await finalizeLegacyScreenStop(
                adapter: adapter,
                engine: engine,
                reason: reason,
                generation: generation,
                materialRoot: materialRoot
            )
        }
        let bounded = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
            await self.settlementSupervisor.settle(ticket: ticket, reason: .requested)
        }
        guard let settled = bounded else {
            // The UI must not spin forever. Keep the real stop running, keep the
            // files untouched, and show what the user can act on now. The
            // settlement event converges the panel when the stop finishes.
            guard generation == sessionGeneration else { return false }
            presentScreenStopRecovery(
                materialRoot: materialRoot,
                reason: AppLocalization.string("The recording is still being saved in the background."),
                canRetry: false
            )
            return false
        }
        guard let settlement = settled else {
            // The ticket no longer owns the supervisor (defensive); seal the files
            // with the adapter's own single stop instead of waiting for an event.
            return await finalizeLegacyScreenStop(
                adapter: adapter,
                engine: engine,
                reason: reason,
                generation: generation,
                materialRoot: materialRoot
            )
        }
        _ = await applyScreenSettlement(
            settlement,
            generation: generation,
            reason: .requested,
            materialRoot: materialRoot,
            engine: engine
        )
        return outcomeState.terminalOutcome == .saved
    }

    /// Publishes a confirmed stop as the session's single saved outcome.
    ///
    /// - Parameters:
    ///   - finalURL: The published MP4.
    ///   - reason: Why the recording stopped, when the user gave one.
    ///   - generation: The session generation this result belongs to.
    ///   - audioFailure: Why the audio track is missing, when it could not start.
    ///   - messageOverride: Replaces the default saved message when the caller has
    ///     something more specific to say.
    /// - Returns: `true` after the saved outcome is presented.
    private func finishScreenRecording(
        finalURL: URL,
        reason: String?,
        generation: UUID,
        audioFailure: String? = nil,
        messageOverride: String? = nil
    ) -> Bool {
        _ = screenStartOwnership.stopConfirmed(generation: generation)
        screenReleaseDestination = nil
        let message: String
        if let messageOverride {
            message = messageOverride
        } else if audioFailure != nil {
            // The video is complete; say plainly that only the audio is missing.
            message = AppLocalization.string(
                "The system audio could not be recorded. The video was saved: %@",
                finalURL.lastPathComponent
            )
        } else if let reason {
            message = AppLocalization.string(
                "Recording stopped and saved (%@): %@",
                reason,
                finalURL.lastPathComponent
            )
        } else {
            message = AppLocalization.string("Recording saved: %@", finalURL.lastPathComponent)
        }
        onMessage?(message, .success)
        finishSession(success: true)
        if RecordingHUDPreferences.revealsOnFinish(in: defaults) {
            revealInFinder(finalURL)
        }
        return true
    }

    /// Legacy single-file finalization kept for the non-segmented path.
    private func finalizeLegacyRecording(
        reason: String?,
        engine: ScreenRecordingEngine,
        generation: UUID
    ) async -> Bool {
        do {
            let finalURL = try await engine.stopAndSave()
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return true }
            return finishScreenRecording(finalURL: finalURL, reason: reason, generation: generation)
        } catch {
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return false }
            await handleRecordingFailure(
                error,
                engine: engine,
                materialRoot: nil,
                errorClass: Self.diagnosticClass(for: error)
            )
            return false
        }
    }

    /// Seals a screen session with the adapter's own single stop.
    ///
    /// Only used when no supervisor ticket owns the start (defensive), so this
    /// path cannot double-stop a supervised session.
    private func finalizeLegacyScreenStop(
        adapter: ScreenRecordingPipelineAdapter,
        engine: ScreenRecordingEngine,
        reason: String?,
        generation: UUID,
        materialRoot: URL?
    ) async -> Bool {
        do {
            let outcome = try await adapter.stopAndSave()
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return outcome.isSaved }
            guard outcome.isSaved, let url = outcome.latestPublishedURL else {
                let failure = ScreenRecordingEngineError.finalizationFailed(
                    outcome.failure ?? "The screen recording did not publish a video segment.",
                    partialURL: materialRoot
                )
                screenPipelineAdapter = nil
                await handleRecordingFailure(
                    failure,
                    engine: engine,
                    materialRoot: materialRoot,
                    errorClass: .writer
                )
                return false
            }
            screenPipelineAdapter = nil
            return finishScreenRecording(
                finalURL: url,
                reason: reason,
                generation: generation,
                audioFailure: outcome.audioFailure
            )
        } catch {
            if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError,
                coordinatorError == .streamStopUnconfirmed
            {
                _ = screenStartOwnership.stopUnconfirmed(generation: generation)
                unconfirmedScreenStop = (adapter, materialRoot)
                guard generation == sessionGeneration else { return false }
                finishSession(success: false, errorClass: .writer)
                presentScreenReleaseCapsule()
                return false
            }
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            guard generation == sessionGeneration else { return false }
            screenPipelineAdapter = nil
            finishSession(success: false, errorClass: .writer)
            onMessage?(
                AppLocalization.string(
                    "The screen recording could not be finalized. The written files were kept."
                ),
                .error
            )
            return false
        }
    }

    /// Applies one screen settlement on the main actor.
    ///
    /// This is the only place a screen stop's outcome reaches the UI: it releases
    /// the start gate even when a newer generation owns the screen, and it never
    /// claims a save without a published segment.
    ///
    /// - Parameters:
    ///   - settlement: The settled stop result.
    ///   - generation: The session generation the settlement belongs to.
    ///   - reason: Whether a request or the deadline produced it.
    ///   - materialRoot: Read-only material directory for a recoverable failure.
    ///   - engine: The engine that may still hold retryable material.
    /// - Returns: `true` only when this call published the saved session.
    @discardableResult
    func applyScreenSettlement(
        _ settlement: RecordingSettlement,
        generation: UUID,
        reason: RecordingSettlementReason,
        materialRoot: URL?,
        engine: ScreenRecordingEngine?
    ) async -> Bool {
        guard markSettlementApplied(generation) else {
            // The event consumer already applied this stop (or the awaiting caller
            // did). Report the real terminal outcome instead of presenting twice.
            return outcomeState.terminalOutcome == .saved
        }
        if let adapter = screenPipelineAdapter {
            lastScreenWriterDiagnostics = await adapter.writerDiagnostics()
        }
        let relay = screenStopRelay
        let unconfirmed = await relay?.wasUnconfirmedStreamStop() ?? false
        let context = takeScreenSettlementContext(
            generation: generation,
            reason: reason,
            materialRoot: materialRoot,
            engine: engine
        )

        if unconfirmed {
            return failUnconfirmedScreenSettlement(generation: generation, materialRoot: materialRoot)
        }

        // The stream confirmed it stopped, so its gate is released even when a
        // newer session already owns the UI.
        _ = screenStartOwnership.stopConfirmed(generation: generation)
        guard generation == sessionGeneration else {
            if case let .screen(outcome) = settlement, outcome.isSaved {
                registerRecoveryMaterials(sessionID: outcome.sessionID, urls: outcome.segmentURLs)
            }
            return false
        }

        if context.intent == .startCleanup {
            return await applyScreenStartCleanup(settlement, context: context)
        }
        return await applyScreenRecordingStop(settlement, context: context)
    }

    /// Reads and clears the per-stop screen state exactly once.
    private func takeScreenSettlementContext(
        generation: UUID,
        reason: RecordingSettlementReason,
        materialRoot: URL?,
        engine: ScreenRecordingEngine?
    ) -> ScreenSettlementContext {
        // A supervisor-initiated stall happens after real media started, so it is
        // a recording stop even when the requested-stop path never ran.
        let intent: ScreenStopIntent
        switch reason {
        case .deadline:
            intent = .startCleanup
        case .promotionStalled:
            intent = .recordingStop
        case .requested:
            intent = screenStopIntent ?? .startCleanup
        }
        let stopReason = screenStopReason
        screenStopIntent = nil
        screenStopReason = nil
        screenStopRelay = nil
        if screenSettlingGeneration == generation { screenSettlingGeneration = nil }
        return ScreenSettlementContext(
            intent: intent,
            stopReason: stopReason,
            reason: reason,
            generation: generation,
            materialRoot: materialRoot,
            engine: engine
        )
    }

    /// Keeps the stream and the gate when its stop was never confirmed.
    private func failUnconfirmedScreenSettlement(generation: UUID, materialRoot: URL?) -> Bool {
        // Do not finalize files. Keep the adapter and the start gate so no
        // second stream can start, and give the user an actionable retry.
        _ = screenStartOwnership.stopUnconfirmed(generation: generation)
        if let adapter = screenPipelineAdapter {
            unconfirmedScreenStop = (adapter, materialRoot)
        }
        guard generation == sessionGeneration else { return false }
        finishSession(success: false, errorClass: .writer)
        presentScreenReleaseCapsule()
        return false
    }

    /// Presents a start that never became a recording, keeping any real material.
    private func applyScreenStartCleanup(
        _ settlement: RecordingSettlement,
        context: ScreenSettlementContext
    ) async -> Bool {
        // The session never became a recording: any written material is
        // recoverable only, and the failure explains why it never started.
        if case let .screen(outcome) = settlement, outcome.isSaved {
            registerRecoveryMaterials(sessionID: outcome.sessionID, urls: outcome.segmentURLs)
        }
        let failure: any Error
        if case let .failed(_, message) = settlement {
            failure = ScreenStartFailureReason.writerFailed(message)
        } else if let adapter = screenPipelineAdapter {
            failure = await classifyScreenStartFailure(adapter: adapter)
        } else {
            failure =
                context.reason == .deadline
                ? RecordingReadinessError.noVideoFrames
                : RecordingReadinessError.videoWriterFailed
        }
        await finishScreenStartWithoutFrames(
            failure: failure,
            materialRoot: context.materialRoot,
            generation: context.generation
        )
        return false
    }

    /// Presents the outcome of a real recording stop.
    private func applyScreenRecordingStop(
        _ settlement: RecordingSettlement,
        context: ScreenSettlementContext
    ) async -> Bool {
        switch settlement {
        case let .screen(outcome):
            guard outcome.isSaved, let url = outcome.latestPublishedURL else {
                return await failScreenRecordingStop(outcome, context: context)
            }
            screenPipelineAdapter = nil
            let stalledMessage =
                context.reason == .promotionStalled
                ? AppLocalization.string(
                    "The screen recording stopped because the interface stopped responding. The video was saved: %@",
                    url.lastPathComponent
                )
                : nil
            return finishScreenRecording(
                finalURL: url,
                reason: context.stopReason,
                generation: context.generation,
                audioFailure: outcome.audioFailure,
                messageOverride: stalledMessage
            )
        case let .failed(_, message):
            screenPipelineAdapter = nil
            finishSession(success: false, errorClass: .writer)
            onMessage?(message, .error)
            return false
        case .audio:
            screenPipelineAdapter = nil
            finishSession(success: false, errorClass: .writer)
            return false
        }
    }

    /// Explains a recording stop that published no segment.
    private func failScreenRecordingStop(
        _ outcome: ScreenRecordingOutcome,
        context: ScreenSettlementContext
    ) async -> Bool {
        // A post-promotion stall with no published segment is still a real
        // recording that could not be finished; say why instead of
        // reporting a generic writer failure.
        if context.reason == .promotionStalled {
            if !outcome.segmentURLs.isEmpty {
                registerRecoveryMaterials(
                    sessionID: outcome.sessionID,
                    urls: outcome.segmentURLs
                )
            }
            screenPipelineAdapter = nil
            finishSession(success: false, errorClass: .timeout)
            onMessage?(
                AppLocalization.string(
                    // swiftlint:disable:next line_length
                    "The screen recording stopped because the interface stopped responding, and the video could not be finalized."
                ),
                .error
            )
            return false
        }
        let failure = ScreenRecordingEngineError.finalizationFailed(
            outcome.failure ?? "The screen recording did not publish a video segment.",
            partialURL: context.materialRoot
        )
        screenPipelineAdapter = nil
        if let engine = context.engine {
            await handleRecordingFailure(
                failure,
                engine: engine,
                materialRoot: context.materialRoot,
                errorClass: .writer
            )
        } else {
            finishSession(success: false, errorClass: .writer)
        }
        return false
    }

    /// The screen writer's privacy-safe counters for this session, when one is live.
    ///
    /// Exposed for the failure classifier and the agent report; it never carries
    /// frame content, window titles, or application names.
    func screenWriterDiagnostics() async -> ScreenWriterDiagnostics? {
        if let adapter = screenPipelineAdapter, let diagnostics = await adapter.writerDiagnostics() {
            lastScreenWriterDiagnostics = diagnostics
            return diagnostics
        }
        return lastScreenWriterDiagnostics
    }

    /// Shows the actionable screen-permission denial.
    ///
    /// The copy names the exact System Settings pane; the guide is opened as well
    /// so the user lands on the switch instead of guessing where it is.
    func presentScreenPermissionDenied() {
        onMessage?(AppLocalization.string(ScreenCapturePermissionCopy.deniedKey), .error)
        onOpenPermissionGuide?()
    }

    /// Builds the capsule payload for a stop that has not confirmed yet.
    func screenStopRecoveryPayload(
        materialRoot: URL? = nil,
        reason: String? = nil,
        canRetry: Bool = true
    ) -> RecordingControlPanelFailure {
        RecordingControlPanelFailure(
            reason: reason
                ?? AppLocalization.string(
                    // swiftlint:disable:next line_length
                    "The capture stream did not confirm it stopped. Your recording was kept; wait for it to stop before starting another one."
                ),
            canRetry: canRetry,
            partialURL: materialRoot ?? unconfirmedScreenStop?.materialRoot
        )
    }

    /// Shows an actionable capsule for a stop that has not confirmed yet.
    ///
    /// Retry re-enters the same stop (never a second stream); Show in Finder opens
    /// the retained material directory. Nothing is deleted.
    func presentScreenStopRecovery(
        materialRoot: URL? = nil,
        reason: String? = nil,
        canRetry: Bool = true
    ) {
        let payload = screenStopRecoveryPayload(
            materialRoot: materialRoot,
            reason: reason,
            canRetry: canRetry
        )
        onFailureChange?(payload)
        presentFailurePanel(payload)
        if panelHiddenByUser || RecordingHUDPreferences.isHidden(in: defaults) {
            onMessage?(payload.reason, .error)
        }
    }

    /// Retries an unconfirmed screen stop, then reports its real result.
    ///
    /// A real start cleanup or stop that is still running is never joined by a
    /// second stop: the retry refuses while one is in flight, and when it does run
    /// it reuses the single `screenStopTask` slot.
    @discardableResult
    func retryUnconfirmedScreenStop() async -> Bool {
        guard let pending = unconfirmedScreenStop,
            !isScreenStopInFlight,
            let generation = screenStartOwnership.ownerGeneration,
            screenStartOwnership.beginStopRetry(generation: generation)
        else { return false }
        let task = Task { try await pending.adapter.stopAndSave() }
        screenStopTask = task
        // Reflect the in-flight retry immediately: Retry disables, no spinner.
        refreshScreenReleaseCapsule()
        do {
            let outcome = try await task.value
            screenStopTask = nil
            _ = screenStartOwnership.stopConfirmed(generation: generation)
            unconfirmedScreenStop = nil
            screenReleaseDestination = nil
            screenPipelineAdapter = nil
            retainedFailure = nil
            clearScreenReleaseCapsule()
            controlPanel?.dismiss()
            controlPanel = nil
            onFailureChange?(nil)
            if outcome.isSaved, let url = outcome.latestPublishedURL {
                let message =
                    outcome.audioFailure == nil
                    ? AppLocalization.string("Recording saved: %@", url.lastPathComponent)
                    : AppLocalization.string(
                        "The system audio could not be recorded. The video was saved: %@",
                        url.lastPathComponent
                    )
                onMessage?(message, .success)
                if RecordingHUDPreferences.revealsOnFinish(in: defaults) { revealInFinder(url) }
                return true
            }
            onMessage?(
                AppLocalization.string(
                    "The screen recording could not be finalized. The written files were kept."
                ),
                .error
            )
            return false
        } catch {
            screenStopTask = nil
            _ = screenStartOwnership.stopUnconfirmed(generation: generation)
            presentScreenReleaseCapsule()
            return false
        }
    }
}
