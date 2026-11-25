import AppKit
import CaptureCore
import Foundation
import SharedKit

/// Audio result construction, terminal completion, and recovery registration.
///
/// Kept apart from the audio lifecycle so the start/stop coordinator stays small;
/// every helper here is called from at least one of the audio, screen, or
/// settlement paths.
extension RecordingSessionController {
    /// Returns `result` with a failure summary, keeping every real measurement.
    static func audioResult(_ result: AudioRecordingResult, failure: String) -> AudioRecordingResult {
        AudioRecordingResult(
            sessionID: result.sessionID,
            kind: result.kind,
            layout: result.layout,
            segmentCount: result.segmentCount,
            droppedRanges: result.droppedRanges,
            checkpointAge: result.checkpointAge,
            failure: failure
        )
    }

    static func audioResultWasSaved(_ result: AudioRecordingResult) -> Bool {
        result.failure == nil && result.segmentCount > 0
    }

    func failedAudioResult(_ error: Error) -> AudioRecordingResult {
        makeAudioResult(failure: AppLocalization.recordingErrorDescription(error))
    }

    func makeAudioResult(failure: String?) -> AudioRecordingResult {
        AudioRecordingResult(
            sessionID: audioSessionID ?? UUID(),
            kind: .audio,
            layout: audioConfiguration?.layout ?? .mixed,
            segmentCount: 0,
            droppedRanges: [],
            checkpointAge: 0,
            failure: failure
        )
    }

    func completeAudioSession(
        with result: AudioRecordingResult,
        outputURL: URL? = nil,
        errorClass: RecordingDiagnosticErrorClass? = nil
    ) {
        guard lastAudioResult == nil else { return }
        lastAudioResult = result
        latestAudioOutputURL = outputURL
        audioProgressTask?.cancel()
        audioProgressTask = nil
        audioStartWatchdogTask?.cancel()
        audioStartWatchdogTask = nil
        audioStartTask = nil
        audioStopRequested = false
        let saved = Self.audioResultWasSaved(result)
        if saved {
            audioStateMachine.apply(.stopCompleted(saved: true))
        } else {
            audioStateMachine.apply(.stopCompleted(saved: false))
            audioStateMachine.apply(.failedRecoverable)
            registerRecoveryMaterials(sessionID: result.sessionID)
            if cancelRequested { outcomeState.beginSession() }
        }
        settleTerminal(wasSaved: saved, errorClass: errorClass)
        updateStatus(audioStateMachine.legacyStatus)
        if saved, result.segmentCount > 0, !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) {
            if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
            controlPanel?.present(state: .audioFinished(
                savedSegments: result.segmentCount,
                outputURL: outputURL,
                previewReady: previewLease != nil,
                previewPlaying: previewPlayer?.isPlaying ?? false
            ))
        } else if !saved {
            presentAudioFailure(reason: result.failure ?? AppLocalization.string("Recording failed"))
        }
        sessionGeneration = UUID()
        activeRecordingKind = nil
        announcedPhase = nil
    }

    /// Registers recoverable material references without copying, moving, or deleting them.
    ///
    /// The URLs come from the existing pipeline ledger (`sessionRoot`) or its latest
    /// published file. Keeping the registration per session avoids a second global
    /// inventory beside the ledger.
    func registerRecoveryMaterials(
        sessionID: UUID,
        pipeline explicitPipeline: RecordingSessionPipeline? = nil
    ) {
        guard audioPipelineStarted || explicitPipeline != nil else { return }
        var urls: [URL] = []
        if let pipeline = explicitPipeline ?? audioPipeline {
            urls.append(pipeline.ledger.sessionRoot.standardizedFileURL)
        }
        registerRecoveryMaterials(sessionID: sessionID, urls: urls)
    }

    /// Registers recoverable material URLs without copying, moving, or deleting them.
    ///
    /// Used by both audio retirement and a cancelled screen start whose late stop
    /// published a segment. The URLs come from the existing pipeline ledger or the
    /// screen outcome; no second inventory is created.
    func registerRecoveryMaterials(sessionID: UUID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        var existing = recoveryMaterialURLs[sessionID] ?? []
        for url in urls where !existing.contains(url) {
            existing.append(url)
        }
        recoveryMaterialURLs[sessionID] = existing
        pendingRecoverySessionIDs.insert(sessionID)
    }

    private func presentAudioFailure(reason: String) {
        let partialURL = audioSessionID.flatMap { recoveryMaterialURLs[$0]?.first }
        let payload = RecordingControlPanelFailure(
            reason: reason,
            canRetry: false,
            partialURL: partialURL
        )
        onFailureChange?(payload)
        presentFailurePanel(payload)
        if panelHiddenByUser || RecordingHUDPreferences.isHidden(in: defaults) {
            onMessage?(AppLocalization.string("Recording failed: %@", reason), .error)
        }
    }
}
