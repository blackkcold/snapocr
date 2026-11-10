import CaptureCore
import SharedKit

extension CaptureViewModel {
    var isRecordingBusy: Bool { recordingStatus.isBusy }

    var canStartRecording: Bool {
        !isRecordingBusy && RecordingCaptureAvailability.canBeginRecording(
            isCapturing: isCapturing,
            isScrollCaptureActive: isScrollCaptureActive
        )
    }

    var needsRecordingQuitConfirmation: Bool {
        recordingSessionController.needsQuitConfirmation
    }

    var isRecordingSaving: Bool {
        recordingSessionController.isSaving
    }

    /// Starts a screen-recording session after checking capture mutual exclusion.
    public func startRecording() {
        guard canStartRecording else { return }
        recordingSessionController.startRecording()
    }

    /// Cancels source selection or the countdown before a recording starts.
    func cancelPendingRecordingStart() {
        recordingSessionController.cancelPendingStart()
    }

    /// Stops the active recording and waits for the MP4 to be finalized and published.
    ///
    /// - Parameter reason: Optional localized context for an automatic or requested stop.
    /// - Returns: Whether the recording was successfully published.
    @discardableResult
    public func stopRecordingAndSave(reason: String? = nil) async -> Bool {
        await recordingSessionController.stopAndSave(reason: reason)
    }

    func stopRecordingAndResolveQuit(reason: String) async -> RecordingSessionTerminalOutcome {
        await recordingSessionController.stopAndResolveForQuit(reason: reason)
    }

    func configureRecording() {
        recordingSessionController.onStatusChange = { [weak self] status in
            self?.recordingStatus = status
        }
        recordingSessionController.onScreenshotShelfRecordingChange = { [weak self] isActive in
            self?.screenshotShelfManager.setRecordingActive(isActive)
        }
        recordingSessionController.onMessage = { [weak self] message, type in
            self?.showToast(message: message, type: type)
        }
        recordingSessionController.onOpenPermissionGuide = { [weak self] in
            self?.openWindow?("permission")
        }
        HotKeyManager.shared.onScreenRecording = { [weak self] in
            self?.startRecording()
        }
    }
}
