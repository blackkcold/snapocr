import AppKit
import CaptureCore
import Foundation
@preconcurrency import ScreenCaptureKit
import SharedKit

/// Source preparation: countdown, source picker, destination recheck, and the
/// agent-channel entry points that skip the picker.
extension RecordingSessionController {
    func startRecording() {
        guard status == .idle else { return }
        guard !hasLiveCaptureResources else {
            presentBlockedStartMessage()
            return
        }
        dismissFailurePanel()
        let request = beginScreenPreparationRequest()
        let preferences = RecordingPreferenceSnapshot(defaults: defaults)
        onScreenshotShelfRecordingChange?(true)
        updateStatus(.selectingSource)
        RecordingSignposts.emit(.preparing, kind: .screen)
        announcePhase(.preparing, kind: .screen)

        screenPreparationTask?.cancel()
        screenPreparationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.isCurrentRequest(request) else { return }
            await self.runScreenPreparation(request: request, preferences: preferences)
        }
    }

    /// Presents the blocking fact for an idle start that still owns resources.
    private func presentBlockedStartMessage() {
        // A pending stream release is the blocking fact; show it again so it
        // can be found later instead of a one-shot toast.
        if presentScreenReleaseCapsuleIfNeeded() { return }
        onMessage?(
            AppLocalization.string(
                "The previous recording is still stopping. Try again when it finishes."
            ),
            .info
        )
    }

    /// Takes the idle session and freezes the screen request identity.
    private func beginScreenPreparationRequest() -> RecordingRequestIdentity {
        let request = RecordingRequestIdentity(kind: .screen)
        sessionGeneration = request.generation
        currentRequest = request
        activeRecordingKind = .screen
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        preparationPhase = .checkingPermission
        startPhase = .startingScreenWriter
        didAwaitFirstVideoFrame = false
        phaseStartedAt = clock.now
        return request
    }

    /// Bounded permission + source enumeration, then the picker or an honest failure.
    private func runScreenPreparation(
        request: RecordingRequestIdentity,
        preferences: RecordingPreferenceSnapshot
    ) async {
        updatePreparationPhase(.checkingPermission)
        // Preflight is synchronous and only decides whether the enumeration
        // below may be bounded. It never decides access by itself: macOS 15
        // ad-hoc builds can report false while access is really granted.
        let accessAlreadyGranted = CGPreflightScreenCaptureAccess()
        if !accessAlreadyGranted {
            guard isCurrentRequest(request), !Task.isCancelled else { return }
            updatePreparationPhase(.waitingForAuthorization)
        }
        let outcome = await ScreenSourceProbe.load()
        // A cancel or a newer attempt discards this late result entirely.
        guard isCurrentRequest(request), status == .selectingSource else { return }

        switch outcome {
        case let .ready(content):
            await presentSourcePicker(request: request, preferences: preferences, content: content)
        case .denied:
            handleScreenProbeDenied(request: request)
        case .timedOut:
            onMessage?(
                AppLocalization.string("Loading the recording sources took too long. Try again."),
                .error
            )
            finishSession(success: false, errorClass: .timeout)
        case let .failed(message):
            onMessage?(
                AppLocalization.string("Could not load recording sources: %@", message),
                .error
            )
            finishSession(success: false, errorClass: .source)
        }
    }

    /// Confirms access from the enumeration, then shows the source picker.
    private func presentSourcePicker(
        request: RecordingRequestIdentity,
        preferences: RecordingPreferenceSnapshot,
        content: SCShareableContent
    ) async {
        _ = await captureOrchestrator.checkPermissionStatus(
            displayCount: content.displays.count
        )
        guard isCurrentRequest(request), status == .selectingSource else { return }
        updatePreparationPhase(.choosingSource)
        showSourcePicker(
            for: request,
            preferences: preferences,
            content: content
        )
    }

    /// Opens the permission guide only when this attempt still owns the picker.
    private func handleScreenProbeDenied(request: RecordingRequestIdentity) {
        let decision = RecordingPermissionDecision.beforePicker(
            accessAvailable: false,
            isCurrentAttempt: isCurrentRequest(request),
            isSelectingSource: status == .selectingSource
        )
        guard case .openPermissionGuide = decision else { return }
        finishSession(success: false, errorClass: .permission)
        onOpenPermissionGuide?()
    }

    private func sourcePickerCompleted(
        _ selection: RecordingSourceSelection?,
        preferences: RecordingPreferenceSnapshot,
        request: RecordingRequestIdentity
    ) async {
        guard isCurrentRequest(request), status == .selectingSource else { return }
        guard let selection else {
            finishSession(success: false)
            return
        }
        let screenMode = preferences.screenAudioMode
        if screenMode == .microphone || screenMode == .systemAndMicrophone {
            updatePreparationPhase(.checkingPermission)
            let permitted = await onRequestScreenMicrophoneAccess?() ?? true
            guard isCurrentRequest(request), status == .selectingSource else { return }
            guard permitted else {
                onMessage?(
                    AppLocalization.string(
                        // swiftlint:disable:next line_length
                        "Microphone access is needed for the selected screen-audio source. Enable it in System Settings, or choose a source without the microphone."
                    ),
                    .error
                )
                onOpenPermissionGuide?()
                finishSession(success: false)
                return
            }
        }
        guard let destination = preferences.destinationDirectory else {
            onMessage?(
                AppLocalization.string("The Movies recording folder is unavailable."),
                .error
            )
            finishSession(success: false)
            return
        }

        let configuration = preferences.configuration(for: selection)
        do {
            try configuration.validate()
            updatePreparationPhase(.verifyingDestination)
            try await RecordingDestinationProbe.prepare(
                directory: destination,
                isCustom: preferences.hasCustomDestination,
                expectedVolumeUUID: preferences.customVolumeUUID
            )
        } catch {
            // The probe runs off the main actor; a cancel or a new attempt may win.
            guard isCurrentRequest(request), status == .selectingSource else { return }
            let message = AppLocalization.string(
                "Unable to start recording: %@",
                AppLocalization.recordingErrorDescription(error)
            )
            onMessage?(message, .error)
            finishSession(success: false)
            return
        }
        guard isCurrentRequest(request), status == .selectingSource else { return }

        // Freeze the session snapshot only now: the identity existed before the
        // permission wait, but the selection is real only after the picker returned.
        activeSession = RecordingSessionSnapshot(
            request: request,
            selection: selection,
            configuration: configuration,
            screenAudioMode: screenAudioModeOverride ?? preferences.screenAudioMode,
            screenAudioBitRate: preferences.screenAudioBitRate,
            destinationDirectory: destination,
            hasCustomDestination: preferences.hasCustomDestination,
            customVolumeUUID: preferences.customVolumeUUID
        )
        beginCountdown(for: selection)
    }

    /// Whether `request` still owns the preparation UI.
    func isCurrentRequest(_ request: RecordingRequestIdentity) -> Bool {
        currentRequest == request && request.isCurrent(generation: sessionGeneration)
    }

    private func beginCountdown(for selection: RecordingSourceSelection) {
        let screen = screen(for: selection.displayID)
        sessionScreen = screen
        let panel = installControlPanel(on: screen)
        // The panel is shown only when the same visibility facts that gate every
        // later `updateStatus` allow it. Presenting a panel that updates will
        // ignore leaves a live but frozen countdown on screen, which is worse than
        // no panel: the user sees a Cancel button that can no longer act.
        if !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) {
            panel.present(state: .countdown(3))
        }
        showCaptureFrame(for: selection)
        updateStatus(.countdown(3))

        countdownTask = Task { @MainActor [weak self] in
            for seconds in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled, self.isCountingDown else { return }
                self.updateStatus(.countdown(seconds))
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled, self.isCountingDown else { return }
            self.countdownTask = nil
            await self.startCapture()
        }
    }

    private func startCapture() async {
        guard status.isBusy, let activeSession, isCurrentRequest(activeSession.request) else { return }
        guard !screenStartOwnership.blocksNewStart else { return }
        guard audioResourceOwner == nil, !isAudioSessionActive, !hasPendingBackgroundFinalization else {
            // A previous audio operation still owns capture resources.
            onMessage?(
                AppLocalization.string(
                    "The previous recording is still stopping. Try again when it finishes."
                ),
                .info
            )
            finishSession(success: false)
            return
        }
        let request = activeSession.request
        let session = activeSession

        // The countdown has finished, but the post-countdown destination check may
        // still be suspended (e.g., a slow external volume). Do not leave the last
        // countdown digit on screen: show the real, cancellable verification step.
        preparationPhase = .verifyingDestination
        startPhase = .startingScreenWriter
        phaseStartedAt = clock.now
        updateStatus(.selectingSource)
        RecordingSignposts.emitStartStage(
            preparationDiagnosticCode(for: .verifyingDestination),
            kind: .screen
        )

        let recheck = RecordingDestinationRecheck(
            request: request,
            verify: {
                try await RecordingDestinationProbe.validateLocation(
                    directory: session.destinationDirectory,
                    isCustom: session.hasCustomDestination,
                    expectedVolumeUUID: session.customVolumeUUID
                )
            },
            isCurrent: { [weak self] request in
                self?.isCurrentRequest(request) ?? false
            },
            onVerified: { [weak self] in
                guard let self else { return }
                await self.beginScreenCapture(session: session, request: request)
            },
            onFailure: { [weak self] error in
                guard let self, self.isCurrentRequest(request) else { return }
                self.onMessage?(
                    AppLocalization.string(
                        "Unable to start recording: %@",
                        AppLocalization.recordingErrorDescription(error)
                    ),
                    .error
                )
                self.finishSession(success: false)
            }
        )
        await recheck.run()
    }

    /// Reserves the screen request identity without the picker (agent channel).
    ///
    /// Mirrors ``beginAudioRequest(requiresMicrophonePermission:)``: it takes the
    /// idle session and exposes a cancellable `.selectingSource` state, so the
    /// caller can drive a real start without clicking the source picker.
    ///
    /// - Returns: The frozen request identity, or `nil` when another session owns capture.
    @discardableResult
    func beginScreenRequest() -> RecordingRequestIdentity? {
        guard status == .idle, !hasLiveCaptureResources, !isAudioSessionActive,
            !hasPendingBackgroundFinalization, !screenStartOwnership.blocksNewStart
        else { return nil }
        let request = RecordingRequestIdentity(kind: .screen)
        dismissFailurePanel()
        sessionGeneration = request.generation
        currentRequest = request
        activeRecordingKind = .screen
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        preparationPhase = .checkingPermission
        startPhase = .startingScreenWriter
        didAwaitFirstVideoFrame = false
        phaseStartedAt = clock.now
        updateStatus(.selectingSource)
        return request
    }

    /// Starts a screen session from an explicit selection, skipping picker and countdown.
    ///
    /// The agent channel uses this so a real screen session runs headless. It reuses
    /// the same snapshot, destination check, permission gate, and settlement path as
    /// the interactive start, so it cannot bypass production behavior.
    ///
    /// - Parameters:
    ///   - selection: The display/window/region the scenario records.
    ///   - request: The identity returned by ``beginScreenRequest()``.
    func startScreen(
        selection: RecordingSourceSelection,
        request: RecordingRequestIdentity
    ) async {
        guard isCurrentRequest(request), status == .selectingSource else { return }
        let preferences = RecordingPreferenceSnapshot(defaults: defaults)
        guard let destination = preferences.destinationDirectory else {
            onMessage?(
                AppLocalization.string("The Movies recording folder is unavailable."),
                .error
            )
            finishSession(success: false)
            return
        }
        let configuration = preferences.configuration(for: selection)
        do {
            try configuration.validate()
            updatePreparationPhase(.verifyingDestination)
            try await RecordingDestinationProbe.prepare(
                directory: destination,
                isCustom: preferences.hasCustomDestination,
                expectedVolumeUUID: preferences.customVolumeUUID
            )
        } catch {
            guard isCurrentRequest(request), status == .selectingSource else { return }
            onMessage?(
                AppLocalization.string(
                    "Unable to start recording: %@",
                    AppLocalization.recordingErrorDescription(error)
                ),
                .error
            )
            finishSession(success: false)
            return
        }
        guard isCurrentRequest(request), status == .selectingSource else { return }
        let session = RecordingSessionSnapshot(
            request: request,
            selection: selection,
            configuration: configuration,
            screenAudioMode: screenAudioModeOverride ?? preferences.screenAudioMode,
            screenAudioBitRate: preferences.screenAudioBitRate,
            destinationDirectory: destination,
            hasCustomDestination: preferences.hasCustomDestination,
            customVolumeUUID: preferences.customVolumeUUID
        )
        activeSession = session
        await beginScreenCapture(session: session, request: request)
    }

    /// Creates the audio request identity before the microphone permission prompt.
    ///
    /// The HUD can then show a real permission wait instead of a silent gap. The
    /// caller must pass this identity to ``startAudio(_:roots:isCustomDestination:expectedVolumeUUID:request:)``
    /// and call ``cancelAudioRequest(_:)`` if permission is denied.
    ///
    /// - Parameter requiresMicrophonePermission: Whether this request will ask for
    ///   microphone access. System-only requests go straight to the destination check.
    /// - Returns: The frozen request identity, or `nil` when another session owns capture.
    @discardableResult
    func beginAudioRequest(requiresMicrophonePermission: Bool = true) -> RecordingRequestIdentity? {
        guard status == .idle, !hasLiveCaptureResources, !isAudioSessionActive,
            !hasPendingBackgroundFinalization
        else { return nil }
        let request = RecordingRequestIdentity(kind: .audio)
        dismissFailurePanel()
        sessionGeneration = request.generation
        currentRequest = request
        activeRecordingKind = .audio
        announcedPhase = nil
        cancelRequested = false
        outcomeState.beginSession()
        preparationPhase = requiresMicrophonePermission ? .checkingPermission : .verifyingDestination
        startPhase = .startingAudioPipeline
        phaseStartedAt = clock.now
        updateStatus(.selectingSource)
        RecordingSignposts.emit(.preparing, kind: .audio)
        announcePhase(.preparing, kind: .audio)
        return request
    }

    /// Settles an audio request that never reached `startAudio`, but only if it
    /// still owns the UI. A late permission result must not cancel a newer request.
    func cancelAudioRequest(_ request: RecordingRequestIdentity) {
        guard isCurrentRequest(request), status == .selectingSource else { return }
        cancelPendingStart()
    }

    /// Presents one preparation step in the floating panel, with its Cancel action.
    func updatePreparationPhase(_ phase: RecordingPreparationPhase) {
        guard status == .selectingSource else { return }
        let elapsed = phaseElapsedMilliseconds()
        preparationPhase = phase
        phaseStartedAt = clock.now
        RecordingSignposts.emitStartStage(
            preparationDiagnosticCode(for: phase),
            kind: currentRecordingKind ?? .screen,
            elapsedMilliseconds: elapsed
        )
        guard !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) else { return }
        if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
        controlPanel?.present(
            state: .preparing(kind: currentRecordingKind ?? .screen, phase: phase)
        )
    }

    func preparationDiagnosticCode(for phase: RecordingPreparationPhase) -> Int {
        switch phase {
        case .checkingPermission: 11
        case .waitingForAuthorization: 12
        case .loadingSources: 13
        case .choosingSource: 14
        case .verifyingDestination: 15
        }
    }

    private func showSourcePicker(
        for request: RecordingRequestIdentity,
        preferences: RecordingPreferenceSnapshot,
        content: SCShareableContent
    ) {
        RecordingSourcePickerPanel.show(
            content: content,
            onComplete: { [weak self] selection in
                Task { @MainActor [weak self] in
                    await self?.sourcePickerCompleted(
                        selection,
                        preferences: preferences,
                        request: request
                    )
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let accessAvailable = await self.captureOrchestrator.checkPermissionStatus()
                    let decision = RecordingPermissionDecision.afterPickerFailure(
                        accessAvailable: accessAvailable,
                        isCurrentAttempt: self.isCurrentRequest(request)
                    )
                    switch decision {
                    case .showPickerFailure:
                        self.onMessage?(message, .error)
                    case .openPermissionGuide:
                        self.onOpenPermissionGuide?()
                    case .showPicker, .ignore:
                        break
                    }
                }
            }
        )
    }
}
