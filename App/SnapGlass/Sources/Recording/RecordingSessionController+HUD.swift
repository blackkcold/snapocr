import AppKit
import CaptureCore
import Foundation
import SharedKit

/// Failure presentation, capture-frame overlay, and panel construction for the recording session.
///
/// Kept in its own file so `RecordingSessionController` stays within the project's file-length
/// budget; every method is driven by panel actions or by finalization.
extension RecordingSessionController {
    func startAudioProgressMonitoring(for pipeline: RecordingSessionPipeline) {
        guard audioProgressTask == nil else { return }
        let stream = pipeline.makeProgressStream()
        audioProgressTask = Task { @MainActor [weak self] in
            for await progress in stream {
                guard !Task.isCancelled, let self,
                      self.audioSessionID == progress.sessionID else { break }
                self.audioProgress = progress
                self.updateAudioSilenceWarning(progress)
                self.updateAudioHUD()
            }
        }
    }

    func presentAudioRecordingHUD() {
        updateAudioHUD()
    }

    func updateAudioHUD() {
        guard !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) else { return }
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
        case .starting, .stopping, .finalizing:
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
    func handleRecordingFailure(_ error: any Error, engine: ScreenRecordingEngine) async {
        let reason = AppLocalization.recordingErrorDescription(error)
        let payload = RecordingControlPanelFailure(
            reason: reason,
            canRetry: await engine.canRetryPublish,
            partialURL: await engine.partialOutputURL
        )
        retainedFailure = (engine, payload)
        onFailureChange?(payload)
        finishSession(success: false)
        presentFailurePanel(payload)
        if RecordingHUDPreferences.isHidden(in: defaults) {
            onMessage?(AppLocalization.string("Recording failed: %@", reason), .error)
        }
    }

    func presentFailurePanel(_ payload: RecordingControlPanelFailure) {
        guard !RecordingHUDPreferences.isHidden(in: defaults) else { return }
        if controlPanel == nil {
            controlPanel = makeControlPanel(on: sessionScreen ?? NSScreen.main)
        }
        controlPanel?.present(state: .failure(payload))
    }

    func retryFailedPublish() async {
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
