import AppKit
import CaptureCore
import Foundation
import SharedKit

@preconcurrency import ScreenCaptureKit

/// Screen capture start, its bounded watchdog, first-frame promotion, and the one
/// initial cleanup for a start that never became a recording.
extension RecordingSessionController {
    /// Starts the screen writer after the destination recheck confirmed it is
    /// still the current request.
    func beginScreenCapture(
        session: RecordingSessionSnapshot,
        request: RecordingRequestIdentity
    ) async {
        guard isCurrentRequest(request),
              let activeSession,
              activeSession.request == request
        else { return }
        let generation = request.generation
        // Access is decided before any writer, journal, or deadline exists. A denial
        // must be visible immediately and must not look like a first-frame timeout.
        guard screenPermissionGate.decide() == .granted else {
            presentScreenPermissionDenied()
            finishSession(success: false, errorClass: .permission)
            return
        }
        guard screenStartOwnership.beginStart(generation: generation) else { return }
        prepareScreenStart(destination: session.destinationDirectory, generation: generation)
        let engine = makeScreenEngine()
        do {
            try await runScreenStart(session: session, request: request, engine: engine, generation: generation)
        } catch {
            await handleScreenStartFailure(error, request: request, generation: generation)
        }
    }

    /// Publishes the truthful `.starting` UI before the writer exists.
    private func prepareScreenStart(destination: URL, generation: UUID) {
        screenReleaseDestination = destination
        didAnnounceScreenRelease = false
        lastScreenWriterDiagnostics = nil
        startPhase = .startingScreenWriter
        phaseStartedAt = clock.now
        updateStatus(.starting)
        RecordingSignposts.emit(.starting, kind: .screen)
        emitStartPhaseSignpost(kind: .screen)
        startScreenStartupWatchdog(generation: generation)
    }

    /// Creates this session's engine and wires the window-exclusion updates.
    private func makeScreenEngine() -> ScreenRecordingEngine {
        let engine = ScreenRecordingEngine()
        self.engine = engine
        screenPipelineAdapter = nil
        RecordingWindowExclusionRegistry.shared.onChange = { [weak engine] windowIDs in
            guard let engine else { return }
            Task { await engine.updateExcludedWindowIDs(windowIDs) }
        }
        return engine
    }

    /// Builds the coordinator and adapter, starts the stream, and arms readiness.
    private func runScreenStart(
        session: RecordingSessionSnapshot,
        request: RecordingRequestIdentity,
        engine: ScreenRecordingEngine,
        generation: UUID
    ) async throws {
        let audioFactoryOverride: ScreenAudioEngineFactoryOverride? = screenAudioFailureInjection
            ? Self.injectedFailingAudioFactory()
            : nil
        let coordinator = try ScreenRecordingSessionCoordinator.makeProduction(
            engine: engine,
            roots: pipelineRoots(for: session.destinationDirectory),
            audioEngineFactoryOverride: audioFactoryOverride
        )
        let adapter = ScreenRecordingPipelineAdapter(coordinator: coordinator)
        let startConfiguration = makeScreenStartConfiguration(for: session)
        screenPipelineAdapter = adapter
        try await adapter.start(
            startConfiguration,
            onFailure: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == self.sessionGeneration,
                          self.screenPipelineAdapter != nil
                    else { return }
                    _ = await self.stopAndSave()
                }
            }
        )
        screenStartWatchdogTask?.cancel()
        screenStartWatchdogTask = nil
        let mayPromote = screenStartOwnership.platformStartReturned(generation: generation)
        guard mayPromote, isCurrentRequest(request) else {
            // A cancel won while the start call was returning. The adapter is
            // live, so it must be stopped exactly once, but the settled UI and
            // any newer request must not be touched.
            runScreenCleanup(adapter: adapter, generation: generation)
            return
        }
        await armScreenFirstFrameWait(
            request: request,
            coordinator: coordinator,
            adapter: adapter,
            generation: generation
        )
    }

    /// Freezes the immutable core start configuration for one session snapshot.
    private func makeScreenStartConfiguration(
        for session: RecordingSessionSnapshot
    ) -> ScreenRecordingStartConfiguration {
        ScreenRecordingPipelineAdapter.makeStartConfiguration(
            ScreenStartConfigurationInput(
                source: session.selection.source,
                video: session.configuration,
                audioMode: session.screenAudioMode,
                audioBitRate: session.screenAudioBitRate,
                destinationDirectory: session.destinationDirectory,
                excludedWindowIDs: excludedWindowIDs,
                sourceDimensions: screenSourceDimensions(for: session.selection)
            )
        )
    }

    /// Arms the first-frame deadline, then presents the promoted `.starting` state.
    private func armScreenFirstFrameWait(
        request: RecordingRequestIdentity,
        coordinator: ScreenRecordingSessionCoordinator,
        adapter: ScreenRecordingPipelineAdapter,
        generation: UUID
    ) async {
        outcomeState.markCaptureAttempted()
        // The platform stream is up; from here the only readiness fact left is
        // a frame the writer actually accepted.
        startPhase = .awaitingFirstVideoFrame
        didAwaitFirstVideoFrame = true
        phaseStartedAt = clock.now
        emitStartPhaseSignpost(kind: .screen)
        // Arm before presenting: a stalled main thread must not be able to skip
        // the first-frame deadline. The stop closure talks to the capture actor
        // directly, so it never depends on the main actor either.
        let relay = ScreenStopFailureRelay()
        screenStopRelay = relay
        screenStopIntent = .startCleanup
        audioSettlementTicket = nil
        screenSettlementTicket = await settlementSupervisor.arm(
            generation: generation,
            kind: .screen,
            deadline: RecordingReadiness.firstVideoFrameDeadline,
            promotionDeadline: RecordingReadiness.firstScreenPresentationDeadline,
            livenessDeadline: RecordingReadiness.recordingLivenessDeadline,
            readiness: .poll {
                if await coordinator.hasWrittenVideoFrame() { return .ready }
                if let reason = await coordinator.writerFailureDescription() {
                    return .failed(reason)
                }
                return .waiting
            },
            stop: { [coordinator] in
                do {
                    return .screen(try await coordinator.stopAndSave())
                } catch {
                    await relay.record(error)
                    return .failed(
                        kind: .screen,
                        message: AppLocalization.recordingErrorDescription(error)
                    )
                }
            }
        )
        // A cancel can win while arming. The cleanup latch then owns the only
        // stop, so the ticket must go away before it can fire a second one. A
        // frame that arrived meanwhile is kept: it already promoted the session.
        guard isCurrentRequest(request),
              screenStartOwnership.ownerGeneration == generation,
              !screenStartOwnership.isStopping
        else {
            if let ticket = screenSettlementTicket {
                await settlementSupervisor.disarm(ticket: ticket)
            }
            screenSettlementTicket = nil
            screenStopRelay = nil
            runScreenCleanup(adapter: adapter, generation: generation)
            return
        }
        // Present only if readiness did not already move the session on.
        if status == .starting {
            updateStatus(.starting)
        }
    }

    /// Bounds the platform screen start independently of first-frame readiness.
    ///
    /// On expiry the UI settles honestly; the late start performs at most one
    /// cleanup and the ownership gate stays closed until that cleanup drains.
    private func startScreenStartupWatchdog(generation: UUID) {
        screenStartWatchdogTask?.cancel()
        screenStartWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: RecordingReadiness.platformStartDeadline)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  generation == self.sessionGeneration,
                  self.screenStartOwnership.isPlatformStartOutstanding,
                  self.status == .starting
            else { return }
            self.outcomeState.markCaptureAttempted()
            // The platform start never returned. The stream may exist and may be
            // capturing, so this is a release-pending state, not a finished
            // session: keep the gate, keep any written material, and leave a
            // persistent, reopenable explanation instead of a one-shot toast.
            self.finishSession(success: false, errorClass: .timeout)
            self.presentScreenReleaseCapsule()
        }
    }

    /// Promotes a screen session after the writer accepted its first frame.
    ///
    /// Driven only by the supervisor's `.mediaStarted` event; there is no
    /// main-actor polling task behind it.
    func handleScreenFirstFrame(generation: UUID) async {
        guard generation == sessionGeneration,
              let request = currentRequest,
              request.generation == generation,
              isCurrentRequest(request)
        else { return }
        // A cancelled first-frame wait must never promote the settled session.
        guard screenStartOwnership.firstFrameAccepted(generation: generation) else { return }
        // From this point the session is a recording, so any later stop — including
        // one the supervisor starts because the interface stalled — must publish the
        // segment instead of classifying the session as a failed start.
        screenStopIntent = .recordingStop
        screenReleaseDestination = nil
        outcomeState.markRecordingStarted()
        recordingStartedAt = Date()
        updateStatus(.recording)
        RecordingSignposts.emit(.recording, kind: .screen)
        announcePhase(.recording, kind: .screen)
        if stopWhenStarted {
            // Readiness already made the session real, so the pending stop goes
            // through the normal recorded path (one stop, one settle).
            _ = await stopAndSave(reason: pendingStopReason)
        } else {
            startMonitoring()
        }
    }

    /// Ends a start whose first-frame gate closed without accepted media.
    ///
    /// The three failure modes stay apart: the writer reported a failure, the
    /// source never delivered a frame, or frames arrived but the writer never
    /// accepted one. The stop already ran in the supervisor; this only presents
    /// the failure and keeps any written material reachable.
    func finishScreenStartWithoutFrames(
        failure: any Error,
        materialRoot: URL?,
        generation: UUID
    ) async {
        guard generation == sessionGeneration else { return }
        screenPipelineAdapter = nil
        if let engine {
            await handleRecordingFailure(
                failure,
                engine: engine,
                materialRoot: materialRoot,
                errorClass: Self.diagnosticClass(for: failure)
            )
        } else {
            finishSession(success: false, errorClass: Self.diagnosticClass(for: failure))
        }
    }

    /// Classifies a first-frame gate timeout without trusting any single signal.
    ///
    /// The three outcomes stay apart: the writer's own start failure, frames that
    /// never reached the capture callback, and frames that arrived but were never
    /// accepted by the writer.
    func classifyScreenStartFailure(
        adapter: ScreenRecordingPipelineAdapter
    ) async -> Error {
        // The supervisor keeps the reason a readiness poll failed with, so a real
        // writer failure is never reported as a plain timeout.
        if let reason = await settlementSupervisor.diagnostics().readinessFailure {
            return ScreenStartFailureReason.writerFailed(reason)
        }
        if let diagnostics = await adapter.writerDiagnostics() {
            if diagnostics.startWritingResult == .failed {
                return ScreenStartFailureReason.writerFailed(
                    diagnostics.lastErrorDescription
                        ?? AppLocalization.string("The media writer could not start.")
                )
            }
            if diagnostics.syncDropCount > 0 {
                return ScreenStartFailureReason.writerNotReady(
                    diagnostics.lastErrorDescription
                        ?? AppLocalization.string(
                            "The media writer was not ready to accept a video sample."
                        )
                )
            }
        }
        if let description = await adapter.failureDescription(), !description.isEmpty {
            return ScreenStartFailureReason.writerFailed(description)
        }
        if !(await adapter.hasAcceptedCaptureFrame()) {
            return RecordingReadinessError.noVideoFrames
        }
        return RecordingReadinessError.videoWriterWaitTimedOut
    }

    /// Performs at most one initial stop for a start that never became a recording.
    ///
    /// The cleanup only releases the ownership gate once the stream stop is
    /// confirmed. An unconfirmed stop keeps the gate closed and raises an
    /// actionable recovery panel instead of spinning.
    func runScreenCleanup(adapter: ScreenRecordingPipelineAdapter, generation: UUID) {
        guard screenCleanupTask == nil else { return }
        guard screenStartOwnership.beginInitialStop(generation: generation) else { return }
        // The gate now means "stop in flight", not "start unknown".
        refreshScreenReleaseCapsule()
        screenCleanupTask = Task { @MainActor [weak self] in
            var stopConfirmed = true
            var outcome: ScreenRecordingOutcome?
            do {
                outcome = try await adapter.stopAndSave()
            } catch {
                if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError,
                   coordinatorError == .streamStopUnconfirmed {
                    stopConfirmed = false
                    if let self, self.screenStartOwnership.ownerGeneration == generation {
                        self.unconfirmedScreenStop = (adapter, await adapter.materialRoot())
                    }
                }
            }
            guard let self else { return }
            self.screenCleanupTask = nil
            if stopConfirmed {
                // Release the gate and remove the old notice in one synchronous
                // step: a new session cannot start in between, so this can never
                // touch a newer session's panel.
                guard self.screenStartOwnership.stopConfirmed(generation: generation) else { return }
                self.unconfirmedScreenStop = nil
                self.screenReleaseDestination = nil
                self.clearScreenReleaseCapsule()
                if let outcome, outcome.isSaved {
                    // This start never became a recording, so it must not reappear as
                    // a saved recording. A late frame may still have written a real
                    // file: keep its URL in the existing recovery registry and never
                    // toast or update the UI for it.
                    self.registerRecoveryMaterials(
                        sessionID: outcome.sessionID,
                        urls: outcome.segmentURLs
                    )
                }
            } else {
                guard self.screenStartOwnership.stopUnconfirmed(generation: generation) else { return }
                self.presentScreenReleaseCapsule()
            }
            if generation != self.sessionGeneration {
                RecordingSignposts.emit(.cancelled, kind: .screen)
            }
        }
    }

    /// Classifies a failed screen start and settles the UI exactly once.
    private func handleScreenStartFailure(
        _ error: any Error,
        request: RecordingRequestIdentity,
        generation: UUID
    ) async {
        screenStartWatchdogTask?.cancel()
        screenStartWatchdogTask = nil
        if await handleUnconfirmedScreenStartStop(error, request: request, generation: generation) {
            return
        }
        // An ordinary failed start retained no stream. Release only the gate
        // this request owns, even if a newer request already replaced the UI.
        let released = screenStartOwnership.startFailed(generation: generation)
        if released { screenReleaseDestination = nil }
        guard isCurrentRequest(request) else {
            if released {
                unconfirmedScreenStop = nil
                clearScreenReleaseCapsule()
            }
            return
        }
        guard released else {
            // A stop already owns this start. Settle honestly and keep the
            // release state visible instead of claiming the failure alone.
            finishSession(success: false, errorClass: Self.diagnosticClass(for: error))
            presentScreenReleaseCapsule()
            return
        }
        screenPipelineAdapter = nil
        screenReleaseDestination = nil
        let message = AppLocalization.string(
            "Unable to start recording: %@",
            AppLocalization.recordingErrorDescription(error)
        )
        onMessage?(message, .error)
        finishSession(success: false, errorClass: Self.diagnosticClass(for: error))
    }

    /// Handles a start that tore down a stream which never confirmed it stopped.
    ///
    /// The adapter is kept so the recovery action can confirm it, and the
    /// ownership gate stays closed so no second stream can start meanwhile.
    ///
    /// - Returns: `true` when this error was that case and the caller must stop.
    private func handleUnconfirmedScreenStartStop(
        _ error: any Error,
        request: RecordingRequestIdentity,
        generation: UUID
    ) async -> Bool {
        guard let coordinatorError = error as? ScreenRecordingSessionCoordinatorError,
              coordinatorError == .streamStopUnconfirmed,
              let adapter = screenPipelineAdapter
        else { return false }
        guard screenStartOwnership.stopUnconfirmed(generation: generation) else { return true }
        unconfirmedScreenStop = (adapter, await adapter.materialRoot())
        screenPipelineAdapter = nil
        guard isCurrentRequest(request) else {
            presentScreenReleaseCapsule()
            return true
        }
        finishSession(success: false, errorClass: .source)
        presentScreenReleaseCapsule()
        return true
    }

    func screenSourceDimensions(for selection: RecordingSourceSelection) -> CGSize {
        if case .display = selection.source { return selection.displayPixelSize }
        guard selection.displayFrame.width > 0, selection.displayFrame.height > 0 else {
            return selection.displayPixelSize
        }
        let scaleX = selection.displayPixelSize.width / selection.displayFrame.width
        let scaleY = selection.displayPixelSize.height / selection.displayFrame.height
        return CGSize(
            width: selection.sourceFrame.width * scaleX,
            height: selection.sourceFrame.height * scaleY
        )
    }

    /// An audio engine factory that always fails, for the agent's degraded scenario.
    ///
    /// Production never calls it; it exists so the harness can prove that a failed
    /// audio track still produces a complete video.
    ///
    /// - Returns: A factory that throws on every call.
    private static func injectedFailingAudioFactory() -> ScreenAudioEngineFactoryOverride {
        { _, _, _ in
            throw AudioRecordingEngineError.startFailed("injected screen audio failure")
        }
    }
}
