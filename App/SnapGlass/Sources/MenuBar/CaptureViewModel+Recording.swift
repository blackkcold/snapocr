import Foundation
import CaptureCore
import SharedKit

enum RecordingAudioPreferenceStore {
    /// AAC bitrates offered by both recording settings pages.
    static let supportedBitRates = [96_000, 128_000, 192_000, 256_000]
    /// Bitrate used when nothing valid is stored.
    static let defaultBitRate = PreferenceDefaults.recordingAudioBitRate
    /// Legacy alias retained for callers. Audio-only recordings keep this key.
    static let audioBitRateKey = PreferenceKeys.recordingAudioBitRate

    static func resolution(in defaults: UserDefaults = .standard) -> RecordingAudioPreferenceMigration.Resolution {
        let persisted: [String: Any]
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            persisted = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        } else {
            persisted = [:]
        }
        let resolution = RecordingAudioPreferenceMigration.resolve(
            audioMode: RecordingAudioPreferenceMigration.mode(
                fromPreferenceValue: persisted[PreferenceKeys.recordingAudioMode] as? String
            ),
            screenMode: RecordingAudioPreferenceMigration.mode(
                fromPreferenceValue: persisted[PreferenceKeys.recordingScreenAudioMode] as? String
            ),
            legacySystemAudio: persisted[PreferenceKeys.recordingSystemAudio] as? Bool
        )

        // Migrate only an actual stored legacy value. Registered/default values are not user choices.
        if resolution.persistScreenMode,
           persisted[PreferenceKeys.recordingSystemAudio] is Bool {
            defaults.set(
                RecordingAudioPreferenceMigration.preferenceValue(for: resolution.screenMode),
                forKey: PreferenceKeys.recordingScreenAudioMode
            )
        }
        return resolution
    }

    static func mode(for kind: RecordingKind, in defaults: UserDefaults = .standard) -> AudioSourceMode {
        let resolution = resolution(in: defaults)
        if kind == .audio, resolution.audioMode == .none {
            return .systemAndMicrophone
        }
        return kind == .audio ? resolution.audioMode : resolution.screenMode
    }

    static func setMode(_ mode: AudioSourceMode, for kind: RecordingKind, in defaults: UserDefaults = .standard) {
        let key = kind == .audio ? PreferenceKeys.recordingAudioMode : PreferenceKeys.recordingScreenAudioMode
        defaults.set(RecordingAudioPreferenceMigration.preferenceValue(for: mode), forKey: key)
    }

    /// Returns the validated AAC bitrate for one recording kind.
    ///
    /// Audio-only recordings keep the legacy `recording_audioBitRate` key; screen
    /// recordings use their independent key. Invalid stored values fall back to
    /// 128 kbps without rewriting the user's preference.
    static func bitRate(for kind: RecordingKind, in defaults: UserDefaults = .standard) -> Int {
        let key = bitRateKey(for: kind)
        let storedBitRate = (defaults.object(forKey: key) as? NSNumber)?.intValue
            ?? defaultBitRate
        return supportedBitRates.contains(storedBitRate) ? storedBitRate : defaultBitRate
    }

    /// Persists a validated AAC bitrate for one recording kind.
    static func setBitRate(_ bitRate: Int, for kind: RecordingKind, in defaults: UserDefaults = .standard) {
        guard supportedBitRates.contains(bitRate) else { return }
        defaults.set(bitRate, forKey: bitRateKey(for: kind))
    }

    private static func bitRateKey(for kind: RecordingKind) -> String {
        kind == .audio
            ? PreferenceKeys.recordingAudioBitRate
            : PreferenceKeys.recordingScreenAudioBitRate
    }

    /// Builds the pipeline roots for a kind's current destination.
    ///
    /// Call this synchronously at invocation, before any permission prompt or
    /// picker, so a later preference change cannot redirect the started session.
    static func pipelineRoots(
        for kind: RecordingKind,
        in defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> RecordingPipelineRoots? {
        guard let directory = RecordingDestinationPreferences.directory(
            for: kind.outputKind,
            in: defaults,
            fileManager: fileManager
        ) else {
            return nil
        }
        return pipelineRoots(for: directory)
    }

    /// Builds the pipeline roots for an already-resolved destination.
    static func pipelineRoots(for directory: URL) -> RecordingPipelineRoots {
        let outputDirectory = directory.standardizedFileURL
        let sessionsDirectory = outputDirectory.appendingPathComponent(
            ".SnapGlassSessions",
            isDirectory: true
        )
        return RecordingPipelineRoots(
            sessionRoot: outputDirectory,
            indexURL: sessionsDirectory.appendingPathComponent("recording-index.json"),
            outputDirectory: outputDirectory
        )
    }

    static func audioConfiguration(in defaults: UserDefaults = .standard) -> AudioRecordingConfiguration {
        let mode = mode(for: .audio, in: defaults)
        let layout: AudioOutputLayout =
            defaults.string(forKey: PreferenceKeys.recordingOutputLayout) == "separateTracks"
                ? .separateTracks
                : .mixed
        let bitRate = bitRate(for: .audio, in: defaults)

        let channels: [RecordingTrackRole: Int]
        switch (mode, layout) {
        case (.system, .mixed):
            channels = [.mixed: 2]
        case (.microphone, .mixed):
            channels = [.mixed: 1]
        case (.systemAndMicrophone, .mixed):
            channels = [.mixed: 2]
        case (.system, .separateTracks):
            channels = [.system: 2]
        case (.microphone, .separateTracks):
            channels = [.microphone: 1]
        case (.systemAndMicrophone, .separateTracks):
            channels = [.system: 2, .microphone: 1]
        case (.none, _):
            // Audio-only mode choices intentionally omit mute; recover safely from stale data.
            return AudioRecordingConfiguration(
                kind: .audio,
                mode: .systemAndMicrophone,
                layout: layout,
                sampleRate: 48_000,
                channelCountByRole: layout == .mixed ? [.mixed: 2] : [.system: 2, .microphone: 1],
                bitRate: bitRate
            )
        }

        return AudioRecordingConfiguration(
            kind: .audio,
            mode: mode,
            layout: layout,
            sampleRate: 48_000,
            channelCountByRole: channels,
            bitRate: bitRate
        )
    }
}

@MainActor
private enum AudioRecordingMenuState {
    static var mode: AudioSourceMode?
    static var startedAt: Date?

    static func clear() {
        mode = nil
        startedAt = nil
    }
}

extension CaptureViewModel {
    var isRecordingBusy: Bool { recordingStatus.isBusy }

    var isAudioRecordingActive: Bool { recordingSessionController.isAudioSessionActive }

    var currentAudioRecordingMode: AudioSourceMode? {
        isAudioRecordingActive ? AudioRecordingMenuState.mode : nil
    }

    var defaultAudioRecordingMode: AudioSourceMode {
        RecordingAudioPreferenceStore.mode(for: .audio)
    }

    func audioRecordingElapsedSeconds(at date: Date = .now) -> TimeInterval {
        guard let startedAt = AudioRecordingMenuState.startedAt else { return 0 }
        return max(0, date.timeIntervalSince(startedAt))
    }

    func setDefaultAudioRecordingMode(_ mode: AudioSourceMode) {
        guard mode != .none else { return }
        RecordingAudioPreferenceStore.setMode(mode, for: .audio)
        objectWillChange.send()
    }

    var canStartRecording: Bool {
        !isRecordingBusy && RecordingCaptureAvailability.canBeginRecording(
            isCapturing: isCapturing,
            isScrollCaptureActive: isScrollCaptureActive
        )
    }

    var needsRecordingQuitConfirmation: Bool {
        recordingSessionController.needsQuitConfirmation
    }

    /// The kind shown by the menu bar and quit confirmation.
    var currentRecordingKind: RecordingKind? {
        recordingSessionController.currentRecordingKind
    }

    var isRecordingSaving: Bool {
        recordingSessionController.isSaving
    }

    /// Starts a screen-recording session after checking capture mutual exclusion.
    public func startRecording() {
        guard canStartRecording else { return }
        recordingSessionController.startRecording()
    }

    /// Starts an audio-only session after the caller has resolved the required system permission.
    /// The controller does not request microphone permission.
    public func startAudioRecording(
        configuration: AudioRecordingConfiguration,
        roots: RecordingPipelineRoots,
        isCustomDestination: Bool,
        expectedVolumeUUID: String? = nil,
        request: RecordingRequestIdentity? = nil
    ) async throws {
        if request == nil {
            guard canStartRecording else { return }
        }
        try await recordingSessionController.startAudio(
            configuration,
            roots: roots,
            isCustomDestination: isCustomDestination,
            expectedVolumeUUID: expectedVolumeUUID,
            request: request
        )
        AudioRecordingMenuState.mode = configuration.mode
        AudioRecordingMenuState.startedAt = .now
        objectWillChange.send()
    }

    /// Starts an audio-only session using the persisted next-session defaults.
    ///
    /// The configuration and destination are captured at invocation, before the
    /// microphone permission prompt, so changing settings cannot redirect this
    /// session after the user has asked for it to start.
    func startDefaultAudioRecording() async {
        guard canStartRecording else { return }
        let configuration = RecordingAudioPreferenceStore.audioConfiguration()
        guard let roots = RecordingAudioPreferenceStore.pipelineRoots(for: .audio) else {
            showToast(
                message: AppLocalization.string("The Movies recording folder is unavailable."),
                type: .error
            )
            return
        }
        RecordingDestinationPreferences.rememberDirectory(roots.outputDirectory)
        // Capture the destination kind at invocation, before the permission
        // prompt, so changing settings cannot redirect this session.
        let isCustomDestination =
            RecordingDestinationPreferences.customDirectory(for: .audio) != nil
        let expectedVolumeUUID =
            RecordingDestinationPreferences.customDirectoryVolumeUUID(for: .audio)
        // The request identity exists before the permission prompt. The permission
        // may return after a cancel, so only this identity may start the session.
        let needsMicrophonePermission =
            configuration.mode == .microphone || configuration.mode == .systemAndMicrophone
        guard let request = recordingSessionController.beginAudioRequest(
            requiresMicrophonePermission: needsMicrophonePermission
        ) else {
            showToast(
                message: AppLocalization.string(
                    "The previous recording is still stopping. Try again when it finishes."
                ),
                type: .info
            )
            return
        }
        guard await ensureMicrophonePermission(for: configuration.mode) else {
            recordingSessionController.cancelAudioRequest(request)
            return
        }

        do {
            try await startAudioRecording(
                configuration: configuration,
                roots: roots,
                isCustomDestination: isCustomDestination,
                expectedVolumeUUID: expectedVolumeUUID,
                request: request
            )
        } catch let error as RecordingReadinessError where error == .supersededStart {
            // The controller already showed the bounded result for this attempt.
            return
        } catch {
            recordingSessionController.cancelAudioRequest(request)
            showToast(message: AppLocalization.recordingErrorDescription(error), type: .error)
        }
    }

    public func openRecordingsWindow() {
        openWindow?(AppWindowPresenter.recordingsWindowID)
    }

    /// Stops audio capture and waits for its final tail and publication work.
    public func stopAudioRecording() async -> AudioRecordingResult {
        _ = await recordingSessionController.stopAndSave()
        AudioRecordingMenuState.clear()
        if let result = recordingSessionController.lastAudioResult { return result }
        return AudioRecordingResult(
            sessionID: recordingSessionController.audioSessionID ?? UUID(),
            kind: .audio,
            layout: recordingSessionController.audioConfiguration?.layout ?? .mixed,
            segmentCount: 0,
            droppedRanges: [],
            checkpointAge: 0,
            failure: AppLocalization.string("Recording failed")
        )
    }

    public func applyAudioRoute(_ event: RouteEvent) async -> RouteCommitResult {
        guard isAudioRecordingActive else {
            return .unchanged(reason: "audio recording is not active")
        }
        guard await ensureMicrophonePermission(for: event.mode) else {
            return .unchanged(reason: "microphone access is unavailable")
        }

        let result = await recordingSessionController.applyRoute(event)
        if case .committed = result {
            AudioRecordingMenuState.mode = event.mode
            objectWillChange.send()
        }
        return result
    }

    func applyAudioSourceMode(_ mode: AudioSourceMode) async {
        let result = await applyAudioRoute(RouteEvent(atSample: 0, mode: mode, deviceID: nil))
        if case let .unchanged(reason) = result, reason != "microphone access is unavailable" {
            showToast(
                message: AppLocalization.string(
                    "The audio source could not be changed; the current source is unchanged."
                ),
                type: .error
            )
        }
    }

    private func ensureMicrophonePermission(
        for mode: AudioSourceMode,
        showsGuidance: Bool = true
    ) async -> Bool {
        guard mode == .microphone || mode == .systemAndMicrophone else { return true }

        let authorizer = AVMicrophoneAuthorizer()
        let initialState = authorizer.currentState()
        var state = initialState
        switch MicrophonePermission.guidance(for: initialState) {
        case .ready:
            return true
        case .requestAccess:
            recordingSessionController.updatePreparationPhase(.waitingForAuthorization)
            state = await authorizer.requestAccess()
        case .openSystemSettings, .useSystemAudioFallback, .ignore:
            break
        }

        guard state == .authorized else {
            guard showsGuidance else { return false }
            let key = initialState == .unknown
                ? "Microphone access is needed to record your voice."
                : "Microphone access is denied. Enable it in System Settings, or use system audio instead."
            showToast(message: AppLocalization.string(key), type: .error)
            return false
        }
        return true
    }

    public func audioRecordingProgress() -> AsyncStream<RecordingProgress> {
        recordingSessionController.makeAudioProgressStream()
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

    /// Brings back the recording panel after the app is reopened from Finder or Spotlight.
    ///
    /// - Returns: `true` when a recording surface or failure was restored and is operable.
    func restoreRecordingControlOnReopen() -> Bool {
        recordingSessionController.restoreControlForReopen()
    }

    func configureRecording() {
        recordingSessionController.onStatusChange = { [weak self] status in
            // The status item label is hosted in a ControlCenter remote scene, and
            // this callback runs inside the recording controller's state change —
            // the same main-actor turn that presents the recording HUD and that
            // follows the menu bar popover dismissal which started the recording.
            // Publishing the status there makes two separate AppKit transactions
            // depend on each other; one runloop turn later is visually identical and
            // keeps the label render off that turn.
            guard let self else { return }
            self.recordingStatusSequence += 1
            let sequence = self.recordingStatusSequence
            Task { @MainActor [weak self] in
                // A real suspension, not just a task hop: the label lives in a
                // ControlCenter remote scene, and resuming inside the same
                // main-queue drain would keep its render in the recording
                // transition turn this deferral exists to leave.
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
                guard let self, sequence == self.recordingStatusSequence else { return }
                self.recordingStatus = status
                if status == .idle {
                    AudioRecordingMenuState.clear()
                }
            }
        }
        recordingSessionController.onScreenshotShelfRecordingChange = { [weak self] isActive in
            self?.setRecordingShelfVisibility(isRecording: isActive)
        }
        recordingSessionController.onMessage = { [weak self] message, type in
            self?.showToast(message: message, type: type)
        }
        recordingSessionController.onOpenPermissionGuide = { [weak self] in
            self?.openWindow?("permission")
        }
        recordingSessionController.onOpenRecordings = { [weak self] in
            self?.openRecordingsWindow()
        }
        recordingSessionController.onFailureChange = { [weak self] failure in
            self?.recordingFailure = failure
        }
        recordingSessionController.onRequestScreenMicrophoneAccess = { [weak self] in
            guard let self else { return false }
            return await self.ensureMicrophonePermission(for: .microphone, showsGuidance: false)
        }
        HotKeyManager.shared.onScreenRecording = { [weak self] in
            self?.startRecording()
        }
        HotKeyManager.shared.onAudioRecording = { [weak self] in
            Task { await self?.startDefaultAudioRecording() }
        }
    }

    func refreshRecordingShelfVisibility() {
        let statusIsRecording = recordingStatus == .starting
            || recordingStatus == .recording
            || recordingStatus == .saving
        setRecordingShelfVisibility(isRecording: isAudioRecordingActive || statusIsRecording)
    }

    private func setRecordingShelfVisibility(isRecording: Bool) {
        let shouldHide = UserDefaults.standard.object(forKey: PreferenceKeys.recordingHideShelfWhileRecording) as? Bool
            ?? PreferenceDefaults.recordingHideShelfWhileRecording
        screenshotShelfManager.setRecordingActive(isRecording, hideShelf: shouldHide)
    }

    /// Looks for interrupted recordings once, right after launch.
    ///
    /// The scan is read-only and runs off the main actor. A failure is logged only:
    /// it must never interrupt startup or show a modal. The recordings window
    /// re-reads the same catalog when the user opens it.
    func scanRecoverableRecordingsAtLaunch() async {
        let recordings = await RecordingRecoveryService.shared.scan()
        logger.info("launch recovery scan found \(recordings.count) recoverable session(s)")
    }
}
