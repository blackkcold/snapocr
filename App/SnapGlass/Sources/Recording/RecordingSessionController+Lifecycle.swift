import AppKit
import CaptureCore
import Foundation
import SharedKit

/// Public session entry points: start, stop, quit resolution, cancel, and teardown.
extension RecordingSessionController {
    func cancelPendingStart() {
        switch status {
        case .selectingSource:
            screenPreparationTask?.cancel()
            screenPreparationTask = nil
            finishSession(success: false, errorClass: .cancelled)
            RecordingSourcePickerPanel.cancelActivePanel()
            AreaSelectionPanel.cancelRecordingRegionSelection()
        case .countdown:
            countdownTask?.cancel()
            finishSession(success: false, errorClass: .cancelled)
        case .starting:
            cancelStartingSession()
        case .idle, .recording, .saving:
            break
        }
    }

    @discardableResult
    func stopAndSave(reason: String? = nil) async -> Bool {
        if isAudioSessionActive || hasPendingBackgroundFinalization {
            let result = await stopAudio()
            return Self.audioResultWasSaved(result)
        }

        switch status {
        case .idle:
            return false
        case .selectingSource, .countdown:
            cancelPendingStart()
            return false
        case .starting:
            stopWhenStarted = true
            if let reason { pendingStopReason = reason }
            let generation = sessionGeneration
            let completed = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
                await self.waitForStopCompletion()
            }
            guard let completed else {
                guard generation == sessionGeneration else { return false }
                cancelStartingSession()
                return false
            }
            return completed
        case .recording:
            return await finalizeRecording(reason: reason)
        case .saving:
            let generation = sessionGeneration
            let completed = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
                await self.waitForStopCompletion()
            }
            guard let completed else {
                guard generation == sessionGeneration else { return false }
                return false
            }
            return completed
        }
    }

    func stopAndResolveForQuit(reason: String) async -> RecordingSessionTerminalOutcome {
        let generation = sessionGeneration
        let kind = currentRecordingKind
        if let kind { RecordingSignposts.emit(.saving, kind: kind) }
        isResolvingQuit = true
        if status == .saving {
            updateStatus(.saving)
        }
        defer { isResolvingQuit = false }

        let resolved = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
            await self.resolveQuitOutcome(reason: reason)
        }
        guard let outcome = resolved else {
            guard generation == sessionGeneration else {
                return outcomeState.terminalOutcome ?? .failed
            }
            // Do not claim saved, and do not settle or drop references for a save
            // that is still live. Keep it represented as saving and return an
            // actionable result; a later quit request joins the same save.
            onMessage?(
                AppLocalization.string(
                    "The recording is still finishing in the background. Try quitting again after it finishes."
                ),
                .info
            )
            if let kind { RecordingSignposts.emit(.quitResolved, kind: kind) }
            return .failed
        }
        if outcome.allowsApplicationQuit { await closeAudioPreview() }
        if let kind { RecordingSignposts.emit(.quitResolved, kind: kind) }
        return outcome
    }

    private func resolveQuitOutcome(reason: String) async -> RecordingSessionTerminalOutcome {
        let outcome: RecordingSessionTerminalOutcome
        if isAudioSessionActive || hasPendingBackgroundFinalization {
            _ = await stopAudio()
            outcome = await waitForBackgroundFinalization()
        } else {
            switch status {
            case .idle:
                outcome = outcomeState.terminalOutcome ?? .noActiveSession
            case .selectingSource, .countdown:
                cancelPendingStart()
                outcome = outcomeState.terminalOutcome ?? .noActiveSession
            case .starting:
                stopWhenStarted = true
                pendingStopReason = reason
                outcome = await waitForTerminalOutcome()
            case .recording:
                _ = await finalizeRecording(reason: reason)
                outcome = outcomeState.terminalOutcome ?? .failed
            case .saving:
                outcome = await waitForTerminalOutcome()
            }
        }
        return outcome
    }

    private func cancelStartingSession() {
        let kind = currentRecordingKind ?? .screen
        cancelRequested = true
        RecordingSignposts.emit(.cancelled, kind: kind)
        if isAudioSessionActive || kind == .audio {
            let generation = sessionGeneration
            audioStopRequested = true
            audioStateMachine.apply(.stopRequested)
            updateStatus(audioStateMachine.legacyStatus)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await RecordingReadiness.awaitBounded(RecordingReadiness.uiSettleDeadline) {
                    await self.stopAudio()
                }
                guard generation == self.sessionGeneration else { return }
                if result == nil { self.forceAudioStartCancellation(generation: generation) }
            }
            return
        }

        guard let request = currentRequest, request.kind == .screen else {
            // No request identity owns this start; settle honestly rather than
            // touching a newer request.
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
            return
        }
        let route = screenStartOwnership.requestCancel(generation: request.generation)
        switch route {
        case .stopWhenStartReturns:
            // The platform start call may never cooperate. Settle the UI now; the
            // late success path performs at most one cleanup when it arrives.
            stopWhenStarted = true
            pendingStopReason = AppLocalization.string("Cancelled")
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
            presentScreenReleaseCapsuleIfNeeded()
        case .cancelFirstFrameWait:
            // The start already returned, so the adapter is live right now. The
            // supervisor owns its single stop; cancelling the first-frame wait here
            // only means "settle the UI now and let that same stop finish".
            stopWhenStarted = false
            pendingStopReason = AppLocalization.string("Cancelled")
            outcomeState.beginSession()
            screenStopIntent = .startCleanup
            screenSettlingGeneration = request.generation
            if let ticket = screenSettlementTicket {
                screenSettlementTicket = nil
                Task { [weak self] in
                    _ = await self?.settlementSupervisor.settle(ticket: ticket, reason: .requested)
                }
            } else if let adapter = screenPipelineAdapter {
                // No ticket owns this start (defensive); its one initial stop is the
                // cleanup latch.
                runScreenCleanup(adapter: adapter, generation: request.generation)
            }
            finishSession(success: false, errorClass: .cancelled)
            presentScreenReleaseCapsuleIfNeeded()
        case .alreadyStopping:
            // A stop is already in flight; settle once and let its real result
            // release (or retain) the gate.
            stopWhenStarted = false
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
            presentScreenReleaseCapsuleIfNeeded()
        case .notStarting:
            break
        case .notOwner:
            // Defensive: the request exists but owns no start. Settle once.
            outcomeState.beginSession()
            finishSession(success: false, errorClass: .cancelled)
        }
    }

    private func forceAudioStartCancellation(generation: UUID) {
        guard generation == sessionGeneration, lastAudioResult == nil else { return }
        switch audioStateMachine.state {
        case .starting, .stopping, .finalizing:
            completeAudioSession(with: failedAudioResult(RecordingReadinessError.cancelledWhileStarting))
        case .idle, .recording, .finished, .failedRecoverable:
            break
        }
    }

    func finishSession(success: Bool, errorClass: RecordingDiagnosticErrorClass? = nil) {
        Task { @MainActor [weak self] in await self?.closeAudioPreview() }
        settleTerminal(wasSaved: success, errorClass: errorClass)
        countdownTask?.cancel()
        countdownTask = nil
        monitoringTask?.cancel()
        monitoringTask = nil
        screenStartWatchdogTask?.cancel()
        screenStartWatchdogTask = nil
        // Never release the screen ownership gate here: a late start or an
        // unconfirmed stream stop must keep it closed until its own path confirms.
        isPresentingScreenRelease = false
        didAnnounceScreenRelease = false
        controlPanel?.dismiss()
        controlPanel = nil
        captureFramePanel?.dismiss()
        captureFramePanel = nil
        recordingStartedAt = nil
        panelHiddenByUser = false
        watchdogReported = false
        engine = nil
        activeSession = nil
        RecordingWindowExclusionRegistry.shared.onChange = { _ in }
        stopWhenStarted = false
        pendingStopReason = nil
        currentRequest = nil
        screenPreparationTask?.cancel()
        screenPreparationTask = nil
        preparationPhase = .checkingPermission
        startPhase = .startingScreenWriter
        onScreenshotShelfRecordingChange?(false)
        updateStatus(.idle)
        sessionGeneration = UUID()
        activeRecordingKind = nil
        announcedPhase = nil
        cancelRequested = false

        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: outcomeState.terminalOutcome == .saved)
        }

        let terminalOutcome = outcomeState.terminalOutcome ?? .failed
        let outcomeWaiters = outcomeWaiters
        self.outcomeWaiters.removeAll()
        for waiter in outcomeWaiters {
            waiter.resume(returning: terminalOutcome)
        }
    }

    func waitForStopCompletion() async -> Bool {
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    func waitForTerminalOutcome() async -> RecordingSessionTerminalOutcome {
        await withCheckedContinuation { continuation in
            outcomeWaiters.append(continuation)
        }
    }
}
