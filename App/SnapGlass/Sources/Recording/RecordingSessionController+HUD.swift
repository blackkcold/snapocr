import AppKit
import CaptureCore
import Foundation
import SharedKit

/// Failure presentation, capture-frame overlay, and panel construction for the recording session.
///
/// Kept in its own file so `RecordingSessionController` stays within the project's file-length
/// budget; every method is driven by panel actions or by finalization.
extension RecordingSessionController {
    func startAudioProgressMonitoring(for pipeline: RecordingSessionPipeline, generation: UUID) {
        guard audioProgressTask == nil else { return }
        let stream = pipeline.makeProgressStream()
        audioProgressTask = Task { @MainActor [weak self] in
            for await progress in stream {
                guard !Task.isCancelled, let self,
                      generation == self.sessionGeneration,
                      self.audioSessionID == progress.sessionID else { break }
                self.audioProgress = progress
                self.updateAudioSilenceWarning(progress)
                self.updateAudioHUD()
            }
        }
    }

    /// Promotes a starting audio session to recording.
    ///
    /// Driven only by the settlement supervisor's `.mediaStarted` event, which it
    /// emits after seeing a real captured sample. The UI never decides readiness
    /// from a progress value of its own.
    func handleAudioReadiness(generation: UUID) {
        guard generation == sessionGeneration,
              audioStateMachine.state == .starting,
              !audioStopRequested
        else { return }
        audioStateMachine.apply(.started)
        outcomeState.markRecordingStarted()
        recordingStartedAt = Date()
        // `updateStatus` is the only entry point that presents: its `.recording` branch
        // shows the audio capsule, so presenting again here would enqueue a second
        // identical state in the same turn.
        updateStatus(audioStateMachine.legacyStatus)
        RecordingSignposts.emit(.recording, kind: .audio)
        announcePhase(.recording, kind: .audio)
    }

    func presentAudioRecordingHUD(ignoringHiddenPreference: Bool = false) {
        updateAudioHUD(ignoringHiddenPreference: ignoringHiddenPreference)
    }

    func updateAudioHUD(ignoringHiddenPreference: Bool = false) {
        if !ignoringHiddenPreference {
            guard !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) else { return }
        }
        if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }

        let progress = audioProgress
        let previewReady = previewTarget != nil
        let previewPlaying = previewPlayer?.isPlaying ?? false
        let state: RecordingControlPanelState
        switch audioStateMachine.state {
        case .recording:
            let duration = progress?.elapsedSeconds ?? 0
            let segmentIndex = Int(
                max(0, duration * 48_000) / Double(RecordingSegmentPolicy.maximumSegmentSamples)
            )
            state = .audioRecording(
                RecordingHUDPresentation(
                    mode: audioCurrentMode ?? audioConfiguration?.mode ?? .systemAndMicrophone,
                    duration: duration,
                    systemLevel: progress?.systemLevel ?? 0,
                    micLevel: progress?.micLevel ?? 0,
                    segmentIndex: segmentIndex,
                    savedCount: progress?.savedSegments ?? 0,
                    state: .recording
                ),
                expanded: audioHUDExpanded,
                silenceWarning: audioSilenceWarningVisible
            )
        case .starting:
            state = .starting(kind: .audio, phase: startPhase)
        case .stopping, .finalizing:
            state = .audioFinalizing(
                savedSegments: progress?.savedSegments ?? 0,
                previewReady: previewReady,
                previewPlaying: previewPlaying
            )
        case .finished:
            let count = lastAudioResult?.segmentCount ?? progress?.savedSegments ?? 0
            state = .audioFinished(
                savedSegments: count,
                outputURL: latestAudioOutputURL,
                previewReady: previewReady,
                previewPlaying: previewPlaying
            )
        case .idle, .failedRecoverable:
            return
        }
        guard let controlPanel else { return }
        controlPanel.update(state: state)
        if !controlPanel.isVisible { controlPanel.present(state: state) }
    }

    func beginPreviewReadinessMonitoring(for pipeline: RecordingSessionPipeline) async {
        guard previewReadinessTask == nil else { return }
        await closeAudioPreview()
        guard previewReadinessTask == nil else { return }
        let generation = previewLifecycleGeneration
        let service = await pipeline.makePreviewService()
        guard previewReadinessTask == nil,
              previewLifecycleGeneration == generation else { return }
        previewService = service
        let stream = pipeline.makePreviewReadyStream()
        previewReadinessTask = Task { @MainActor [weak self] in
            for await target in stream {
                guard !Task.isCancelled, let self else { break }
                self.previewLoadTask?.cancel()
                let previousLoad = self.previewLoadTask
                self.previewLoadTask = nil
                self.previewTarget = nil
                self.updateAudioHUD()
                await previousLoad?.value
                guard !Task.isCancelled else { break }
                await self.releaseAudioPreviewLease()
                guard !Task.isCancelled else { break }
                self.previewTarget = target
                self.updateAudioHUD()
            }
        }
    }

    func closeAudioPreview() async {
        previewLifecycleGeneration += 1
        let service = previewService
        previewTarget = nil
        previewService = nil
        previewReadinessTask?.cancel()
        previewLoadTask?.cancel()
        let loadTask = previewLoadTask
        let readinessTask = previewReadinessTask
        previewLoadTask = nil
        previewReadinessTask = nil
        let lease = detachAudioPreview()
        enqueueAudioPreviewRelease(lease, service: service)
        await loadTask?.value
        await readinessTask?.value
        let releaseTask = previewReleaseTask
        let releaseGeneration = previewReleaseGeneration
        await releaseTask?.value
        if previewReleaseGeneration == releaseGeneration { previewReleaseTask = nil }
        updateAudioHUD()
    }

    func playAudioPreview() {
        guard let target = previewTarget, let service = previewService else { return }
        if let lease = previewLease {
            startAudioPreview(lease)
            return
        }
        guard previewLoadTask == nil else { return }
        previewLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.previewLoadTask = nil }
            await self.loadAudioPreview(for: target, service: service)
            guard !Task.isCancelled,
                  self.previewTarget == target,
                  let lease = self.previewLease
            else { return }
            self.startAudioPreview(lease)
        }
    }

    private func startAudioPreview(_ lease: PreviewLease) {
        guard previewLease?.id == lease.id else { return }
        let player = RecordingAudioPreviewPlayer()
        previewPlayer = player
        do {
            try player.play(urls: lease.mediaURLs) { [weak self, weak player] in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player,
                          self.previewPlayer === player,
                          self.previewLease?.id == lease.id else { return }
                    await self.releaseAudioPreviewLease()
                }
            }
            updateAudioHUD()
        } catch {
            onMessage?(AppLocalization.string("Audio preview could not be started."), .error)
            Task { @MainActor [weak self, weak player] in
                guard let self, let player,
                      self.previewPlayer === player,
                      self.previewLease?.id == lease.id else { return }
                await self.releaseAudioPreviewLease()
            }
        }
    }

    func stopAudioPreview() {
        let service = previewService
        let lease = detachAudioPreview()
        enqueueAudioPreviewRelease(lease, service: service)
    }

    func openRecording(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadAudioPreview(for target: PreviewTarget, service: RecordingPreviewService) async {
        await releaseAudioPreviewLease()
        guard !Task.isCancelled else { return }
        do {
            let lease = try await service.leasePreview(for: target, duration: 24 * 60 * 60)
            guard !Task.isCancelled else {
                await service.release(lease)
                return
            }
            previewService = service
            previewTarget = target
            previewLease = lease
            updateAudioHUD()
        } catch {
            guard !Task.isCancelled else { return }
            onMessage?(AppLocalization.string("Audio preview is not ready."), .info)
        }
    }

    private func releaseAudioPreviewLease() async {
        let service = previewService
        let lease = detachAudioPreview()
        enqueueAudioPreviewRelease(lease, service: service)
        let releaseTask = previewReleaseTask
        let releaseGeneration = previewReleaseGeneration
        await releaseTask?.value
        if previewReleaseGeneration == releaseGeneration { previewReleaseTask = nil }
    }

    private func detachAudioPreview() -> PreviewLease? {
        let player = previewPlayer
        previewPlayer = nil
        player?.stop()
        let lease = previewLease
        previewLease = nil
        updateAudioHUD()
        return lease
    }

    private func enqueueAudioPreviewRelease(
        _ lease: PreviewLease?,
        service: RecordingPreviewService?
    ) {
        guard let lease, let service else { return }
        let previous = previewReleaseTask
        previewReleaseGeneration += 1
        previewReleaseTask = Task { @MainActor in
            await previous?.value
            await service.release(lease)
        }
    }

    private func updateAudioSilenceWarning(_ progress: RecordingProgress) {
        let mode = audioCurrentMode ?? audioConfiguration?.mode ?? .none
        let hasSignal: Bool
        switch mode {
        case .system: hasSignal = progress.systemLevel > 0
        case .microphone: hasSignal = progress.micLevel > 0
        case .systemAndMicrophone: hasSignal = progress.systemLevel > 0 || progress.micLevel > 0
        case .none: hasSignal = true
        }
        guard !audioSilenceWarningShown else {
            if hasSignal { audioSilenceWarningVisible = false }
            return
        }
        guard !hasSignal else {
            audioSilenceStartedAt = nil
            audioSilenceWarningVisible = false
            return
        }
        let now = ContinuousClock.now
        guard let startedAt = audioSilenceStartedAt else {
            audioSilenceStartedAt = now
            return
        }
        guard startedAt.duration(to: now) >= .seconds(30) else { return }
        audioSilenceWarningShown = true
        audioSilenceWarningVisible = true
    }

    /// Keeps a failed session visible and actionable instead of dismissing it behind a toast.
    ///
    /// - Parameters:
    ///   - error: The failure to explain in the panel.
    ///   - engine: The engine that still owns retryable material.
    ///   - materialRoot: A read-only session directory to reveal when no partial file exists.
    ///   - errorClass: Optional privacy-safe class for the terminal signpost.
    func handleRecordingFailure(
        _ error: any Error,
        engine: ScreenRecordingEngine,
        materialRoot: URL? = nil,
        errorClass: RecordingDiagnosticErrorClass? = nil
    ) async {
        let reason = AppLocalization.recordingErrorDescription(error)
        let payload = RecordingControlPanelFailure(
            reason: reason,
            canRetry: await engine.canRetryPublish,
            partialURL: await engine.partialOutputURL ?? materialRoot
        )
        let wasHidden = panelHiddenByUser || RecordingHUDPreferences.isHidden(in: defaults)
        retainedFailure = (engine, payload)
        onFailureChange?(payload)
        finishSession(success: false, errorClass: errorClass ?? Self.diagnosticClass(for: error))
        if !wasHidden { presentFailurePanel(payload) }
        if wasHidden {
            onMessage?(AppLocalization.string("Recording failed: %@", reason), .error)
        }
    }

    /// Builds the capture-release capsule payload for the current phase.
    ///
    /// "Stream release not confirmed" and "file not sealed yet" are different
    /// statements: this payload is only used while the stream's release is the
    /// open question, never for a `.saving` session.
    func screenReleasePayload(materialRoot: URL? = nil) -> RecordingControlPanelFailure {
        let phase = screenReleasePhase ?? .startUnconfirmed
        let reason: String
        switch phase {
        case .startUnconfirmed:
            reason = AppLocalization.string(
                "SnapGlass has not confirmed what happened to the capture it tried to start, so recording stays disabled. If this does not clear, quit SnapGlass and open it again. Anything already written stays in your recordings folder."
            )
        case .stopUnconfirmed:
            reason = AppLocalization.string(
                "SnapGlass has asked the capture stream to stop and has not confirmed it yet. Recording stays disabled until it does. If this does not clear, quit SnapGlass and open it again. Written files are kept."
            )
        case .stopRejected:
            reason = AppLocalization.string(
                "The capture stream did not confirm it stopped. Your recording was kept; wait for it to stop before starting another one."
            )
        }
        return RecordingControlPanelFailure(
            reason: reason,
            canRetry: phase == .stopRejected && !isScreenStopInFlight,
            partialURL: unconfirmedScreenStop?.materialRoot ?? materialRoot ?? screenReleaseDestination
        )
    }

    /// Presents the capture-release capsule when a stream release is still open.
    @discardableResult
    func presentScreenReleaseCapsuleIfNeeded() -> Bool {
        guard screenReleasePhase != nil else { return false }
        didAnnounceScreenRelease = false
        presentScreenReleaseCapsule()
        return true
    }

    /// Shows the release capsule with its Finder target and explicit exit.
    ///
    /// It is static (never a spinner), never claims the stream stopped, and stays
    /// findable again after the app is reopened from Finder or Spotlight.
    func presentScreenReleaseCapsule(
        materialRoot: URL? = nil,
        ignoringHiddenPreference: Bool = false
    ) {
        guard screenReleasePhase != nil else { return }
        let payload = screenReleasePayload(materialRoot: materialRoot)
        onFailureChange?(payload)
        if ignoringHiddenPreference {
            panelHiddenByUser = false
            presentReopenPanel(.failure(payload))
        } else {
            presentFailurePanel(payload)
        }
        let isVisible = controlPanel?.isVisible ?? false
        isPresentingScreenRelease = isVisible
        if !isVisible, !didAnnounceScreenRelease {
            didAnnounceScreenRelease = true
            onMessage?(payload.reason, .info)
        }
    }

    /// Updates the release wording when the phase advances, without re-announcing.
    func refreshScreenReleaseCapsule() {
        guard isPresentingScreenRelease, screenReleasePhase != nil else { return }
        presentScreenReleaseCapsule()
    }

    /// Removes the release capsule after the gate is actually released.
    ///
    /// Call only in the same synchronous step that releases the screen start
    /// ownership gate, so a newer session can never be showing when this runs.
    func clearScreenReleaseCapsule() {
        didAnnounceScreenRelease = false
        guard isPresentingScreenRelease else { return }
        isPresentingScreenRelease = false
        if let failure = retainedFailure?.payload {
            onFailureChange?(failure)
            presentFailurePanel(failure)
            return
        }
        onFailureChange?(nil)
        controlPanel?.dismiss()
        controlPanel = nil
    }

    /// Restores a usable control surface after the app is reopened from Finder or Spotlight.
    ///
    /// This deliberately ignores the "hide the recording panel" preference and the
    /// in-memory hide flag: an explicit reopen is a request for controls, not for a
    /// silent session with no way to stop it.
    ///
    /// - Returns: `true` when a recording surface or a failure was brought back.
    @discardableResult
    func restoreControlForReopen() -> Bool {
        panelHiddenByUser = false
        // A pending stream release outranks a failure: it is what keeps recording
        // disabled, and it must stay visible even after the session was cleared.
        if screenReleasePhase != nil {
            didAnnounceScreenRelease = false
            presentScreenReleaseCapsule(ignoringHiddenPreference: true)
            return controlPanel?.isVisible ?? false
        }
        if let failure = retainedFailure?.payload {
            presentReopenPanel(.failure(failure))
            return true
        }
        if isAudioSessionActive {
            presentAudioRecordingHUD(ignoringHiddenPreference: true)
            return controlPanel?.isVisible ?? false
        }
        switch status {
        case .selectingSource:
            presentReopenPanel(
                .preparing(kind: currentRecordingKind ?? .screen, phase: preparationPhase)
            )
            return controlPanel?.isVisible ?? false
        case .countdown:
            guard let seconds = countdownSeconds else { return false }
            presentReopenPanel(.countdown(seconds))
            return controlPanel?.isVisible ?? false
        case .starting:
            let kind = currentRecordingKind ?? .screen
            presentReopenPanel(
                .starting(kind: kind, phase: startPhase)
            )
            return controlPanel?.isVisible ?? false
        case .recording:
            presentReopenPanel(.recording(startedAt: recordingStartedAt ?? Date()))
            return controlPanel?.isVisible ?? false
        case .saving:
            presentReopenPanel(
                .saving(
                    kind: currentRecordingKind ?? .screen,
                    fileName: nil,
                    isBeforeQuit: isResolvingQuit
                )
            )
            return controlPanel?.isVisible ?? false
        case .idle:
            return false
        }
    }

    /// Presents a panel state for an explicit reopen, bypassing hide preferences.
    private func presentReopenPanel(_ state: RecordingControlPanelState) {
        if controlPanel == nil {
            controlPanel = makeControlPanel(on: sessionScreen ?? NSScreen.main)
        }
        controlPanel?.present(state: state)
    }

    private var countdownSeconds: Int? {
        if case let .countdown(seconds) = status { return seconds }
        return nil
    }

    func presentFailurePanel(_ payload: RecordingControlPanelFailure) {
        guard !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) else { return }
        if controlPanel == nil {
            controlPanel = makeControlPanel(on: sessionScreen ?? NSScreen.main)
        }
        controlPanel?.present(state: .failure(payload))
    }

    func retryFailedPublish() async {
        if unconfirmedScreenStop != nil {
            await retryUnconfirmedScreenStop()
            return
        }
        guard let retainedFailure else { return }
        do {
            let url = try await retainedFailure.engine.retryPublish()
            self.retainedFailure = nil
            onFailureChange?(nil)
            controlPanel?.dismiss()
            controlPanel = nil
            onMessage?(AppLocalization.string("Recording saved: %@", url.lastPathComponent), .success)
            if RecordingHUDPreferences.revealsOnFinish(in: defaults) {
                revealInFinder(url)
            }
        } catch {
            let payload = RecordingControlPanelFailure(
                reason: AppLocalization.recordingErrorDescription(error),
                canRetry: await retainedFailure.engine.canRetryPublish,
                partialURL: await retainedFailure.engine.partialOutputURL
            )
            self.retainedFailure = (retainedFailure.engine, payload)
            onFailureChange?(payload)
            controlPanel?.update(state: .failure(payload))
        }
    }

    func dismissFailurePanel() {
        retainedFailure = nil
        onFailureChange?(nil)
        isPresentingScreenRelease = false
        didAnnounceScreenRelease = false
        controlPanel?.dismiss()
        controlPanel = nil
        Task { @MainActor [weak self] in await self?.closeAudioPreview() }
    }

    func hidePanelWhileSaving() {
        panelHiddenByUser = true
        controlPanel?.dismiss()
        Task { @MainActor [weak self] in await self?.closeAudioPreview() }
    }

    func revealInFinder(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func storeCorner(_ corner: RecordingHUDCorner) {
        defaults.set(corner.rawValue, forKey: PreferenceKeys.recordingHUDCorner)
    }

    func makeControlPanel(on screen: NSScreen?) -> RecordingControlPanel {
        RecordingControlPanel(
            on: screen,
            corner: RecordingHUDPlacement.corner(
                rawValue: RecordingHUDPreferences.cornerIdentifier(in: defaults)
            ),
            opacity: RecordingHUDPreferences.opacity(in: defaults),
            hoverRestore: RecordingHUDPreferences.hoverRestore(in: defaults),
            actions: RecordingControlPanelActions(
                onCancel: { [weak self] in self?.cancelPendingStart() },
                onStop: { [weak self] in
                    Task { @MainActor [weak self] in
                        _ = await self?.stopAndSave()
                    }
                },
                onRetry: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.retryFailedPublish()
                    }
                },
                onReveal: { [weak self] url in self?.revealInFinder(url) },
                onDismiss: { [weak self] in self?.dismissFailurePanel() },
                onHideWhileSaving: { [weak self] in self?.hidePanelWhileSaving() },
                onCornerChange: { [weak self] corner in self?.storeCorner(corner) },
                onToggleAudioDetails: { [weak self] in
                    guard let self else { return }
                    self.audioHUDExpanded.toggle()
                    self.updateAudioHUD()
                },
                onPreview: { [weak self] in self?.playAudioPreview() },
                onStopPreview: { [weak self] in self?.stopAudioPreview() },
                onOpenLatest: { [weak self] url in self?.openRecording(url) },
                onOpenRecordings: { [weak self] in self?.onOpenRecordings?() },
                onJoinExport: { [weak self] in self?.onOpenRecordings?() }
            )
        )
    }

    func showCaptureFrame(for selection: RecordingSourceSelection) {
        guard RecordingHUDPreferences.showsCaptureFrame(in: defaults),
              let rect = captureFrameRect(for: selection) else { return }
        let panel = RecordingCaptureFramePanel(rect: rect)
        captureFramePanel = panel
        panel.present()
    }

    var excludedWindowIDs: Set<CGWindowID> {
        var identifiers = RecordingWindowExclusionRegistry.shared.currentWindowIDs
        identifiers.formUnion(controlPanel?.excludedWindowIDs ?? [])
        if let captureFramePanel {
            identifiers.formUnion(captureFramePanel.excludedWindowIDs)
        }
        return identifiers
    }

    func captureFrameRect(for selection: RecordingSourceSelection) -> CGRect? {
        guard let screen = screen(for: selection.displayID) else { return nil }
        let localRect: CGRect
        switch selection.source {
        case .display:
            localRect = CGRect(origin: .zero, size: selection.displayFrame.size)
        case let .region(_, sourceRect):
            localRect = sourceRect
        case .window:
            localRect = CGRect(
                x: selection.sourceFrame.minX - selection.displayFrame.minX,
                y: selection.sourceFrame.minY - selection.displayFrame.minY,
                width: selection.sourceFrame.width,
                height: selection.sourceFrame.height
            )
        }
        return RecordingCaptureFrameGeometry.appKitRect(
            localRect: localRect,
            displayFrame: selection.displayFrame,
            appKitScreenFrame: screen.frame
        )
    }

    /// Surfaces "recording but no frames" instead of leaving a frozen timer that looks healthy.
    func reportMissingFramesIfNeeded() async {
        guard let engine, let startedAt = recordingStartedAt, !panelHiddenByUser else { return }
        let hasFrames = await engine.hasAcceptedVideoFrame
        if hasFrames {
            if watchdogReported {
                watchdogReported = false
                controlPanel?.update(state: .recording(startedAt: startedAt))
            }
            return
        }
        guard !watchdogReported, Date().timeIntervalSince(startedAt) >= 2 else { return }
        watchdogReported = true
        controlPanel?.update(
            state: .notice(AppLocalization.string("No frames are arriving from the selected source."))
        )
    }

}
