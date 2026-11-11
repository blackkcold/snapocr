import AppKit
import CaptureCore
import Foundation
import SharedKit

/// Failure presentation, capture-frame overlay, and panel construction for the recording session.
///
/// Kept in its own file so `RecordingSessionController` stays within the project's file-length
/// budget; every method is driven by panel actions or by finalization.
extension RecordingSessionController {
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
    }

    func hidePanelWhileSaving() {
        panelHiddenByUser = true
        controlPanel?.dismiss()
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
                onCornerChange: { [weak self] corner in self?.storeCorner(corner) }
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
        var identifiers = controlPanel?.excludedWindowIDs ?? []
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
