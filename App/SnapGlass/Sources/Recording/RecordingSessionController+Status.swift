import AppKit
import CaptureCore
import Foundation
import SharedKit

/// Status presentation, HUD suppression logging, phase signposts, and VoiceOver.
extension RecordingSessionController {
    var isCountingDown: Bool {
        if case .countdown = status { return true }
        return false
    }

    func updateStatus(_ status: RecordingSessionStatus) {
        self.status = status
        onStatusChange?(status)
        guard !panelHiddenByUser else {
            logSuppressedHUDUpdate(status)
            return
        }
        switch status {
        case .countdown(let seconds):
            controlPanel?.update(state: .countdown(seconds))
        case .starting:
            let kind = currentRecordingKind ?? .screen
            let state = RecordingControlPanelState.starting(kind: kind, phase: startPhase)
            if audioStateMachine.state == .starting {
                if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
                controlPanel?.present(state: state)
                return
            }
            controlPanel?.update(state: state)
        case .recording:
            if audioStateMachine.state == .recording {
                presentAudioRecordingHUD()
                return
            }
            let startedAt = recordingStartedAt ?? Date()
            recordingStartedAt = startedAt
            controlPanel?.update(state: .recording(startedAt: startedAt))
        case .saving:
            if audioStateMachine.state == .stopping || audioStateMachine.state == .finalizing {
                updateAudioHUD()
                return
            }
            controlPanel?.update(state: .saving(
                kind: currentRecordingKind ?? .screen,
                fileName: nil,
                isBeforeQuit: isResolvingQuit
            ))
        case .idle, .selectingSource:
            if status == .selectingSource {
                if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
                controlPanel?.present(
                    state: .preparing(
                        kind: currentRecordingKind ?? .screen,
                        phase: preparationPhase
                    )
                )
            }
        }
    }

    /// Records a status that never reached the control panel.
    ///
    /// A countdown tick is intentionally silent. A transition into a live session
    /// is not: if it is dropped, the user sees a panel that can no longer act
    /// while capture is already running. Persisting that fact makes the next
    /// occurrence diagnosable from the log alone.
    private func logSuppressedHUDUpdate(_ status: RecordingSessionStatus) {
        let name: String
        switch status {
        case .starting:
            name = "starting"
        case .recording:
            name = "recording"
        case .saving:
            name = "saving"
        case .idle, .selectingSource, .countdown:
            return
        }
        logger.fault(
            // OSLog interpolation cannot be concatenated.
            // swiftlint:disable:next line_length
            "HUD update suppressed status=\(name, privacy: .public) panelVisible=\(self.controlPanel?.isVisible == true, privacy: .public)"
        )
    }

    /// Milliseconds since the current phase started, or `nil` when unknown.
    func phaseElapsedMilliseconds() -> Int? {
        guard let phaseStartedAt else { return nil }
        return clock.milliseconds(since: phaseStartedAt)
    }

    /// Emits one numeric start-stage signpost for the current phase.
    func emitStartPhaseSignpost(kind: RecordingKind) {
        RecordingSignposts.emitStartStage(
            startPhase.diagnosticCode,
            kind: kind,
            elapsedMilliseconds: phaseElapsedMilliseconds()
        )
    }

    /// Maps an error to the numeric signpost class. Never carries error text.
    static func diagnosticClass(for error: Error) -> RecordingDiagnosticErrorClass {
        if let readiness = error as? RecordingReadinessError {
            switch readiness {
            case .videoWriterFailed, .videoWriterWaitTimedOut:
                return .writer
            case .noVideoFrames, .noAudioSamples:
                return .source
            case .sourceListTimedOut, .startTimedOut, .uiWaitTimedOut:
                return .timeout
            case .cancelledWhileStarting, .supersededStart:
                return .cancelled
            }
        }
        if let engineError = error as? ScreenRecordingEngineError {
            switch engineError {
            case .sourceUnavailable, .invalidRegion, .invalidSourceDimensions, .invalidOutputDimensions:
                return .source
            case .writerInputUnavailable, .recordingFailed, .finalizationFailed, .previousStreamNotStopped:
                return .writer
            }
        }
        if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError {
            switch coordinatorError {
            case .streamStopUnconfirmed, .noPublishedSegments, .audioFinalizationFailed:
                return .writer
            case .alreadyStarted, .notStarted, .invalidConfiguration:
                return .unknown
            }
        }
        if error is ScreenStartFailureReason { return .writer }
        return .unknown
    }

    /// Posts one kind-aware VoiceOver announcement per phase transition.
    func announcePhase(_ phase: RecordingPhase, kind: RecordingKind) {
        guard announcedPhase != phase else { return }
        let message: String?
        switch phase {
        case .preparing:
            message = AppLocalization.string(
                kind == .audio ? "Preparing audio recording" : "Preparing screen recording"
            )
        case .starting:
            message = nil
        case .recording:
            message = AppLocalization.string(kind == .audio ? "Recording audio" : "Recording screen")
        case .saving:
            message = AppLocalization.string(
                isResolvingQuit
                    ? "Saving recording before quitting"
                    : (kind == .audio ? "Saving audio recording" : "Saving screen recording")
            )
        case .finished:
            message = AppLocalization.string(
                kind == .audio ? "Audio recording saved" : "Screen recording saved"
            )
        case .failed:
            message = AppLocalization.string("Recording failed")
        case .cancelled, .quitResolved:
            message = nil
        }
        announcedPhase = phase
        guard let message else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
