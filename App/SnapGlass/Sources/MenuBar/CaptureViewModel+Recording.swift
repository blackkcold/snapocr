import Foundation
import CaptureCore
import SharedKit

enum RecordingAudioPreferenceStore {
    static let audioBitRateKey = "recording_audioBitRate"

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

    static func audioConfiguration(in defaults: UserDefaults = .standard) -> AudioRecordingConfiguration {
        let mode = mode(for: .audio, in: defaults)
        let layout: AudioOutputLayout = defaults.string(forKey: PreferenceKeys.recordingOutputLayout) == "separateTracks"
            ? .separateTracks
            : .mixed
        let storedBitRate = defaults.object(forKey: audioBitRateKey) as? Int ?? 128_000
        let bitRate = [96_000, 128_000, 192_000, 256_000].contains(storedBitRate) ? storedBitRate : 128_000

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
    public func startAudioRecording(configuration: AudioRecordingConfiguration) async throws {
        guard canStartRecording else { return }
        try await recordingSessionController.startAudio(configuration)
        AudioRecordingMenuState.mode = configuration.mode
        AudioRecordingMenuState.startedAt = .now
        objectWillChange.send()
    }

    /// Starts an audio-only session using the persisted next-session defaults.
    func startDefaultAudioRecording() async {
        guard canStartRecording else { return }
        let configuration = RecordingAudioPreferenceStore.audioConfiguration()
        guard await ensureMicrophonePermission(for: configuration.mode) else { return }

        do {
            try await startAudioRecording(configuration: configuration)
        } catch {
            showToast(message: AppLocalization.recordingErrorDescription(error), type: .error)
        }
    }

    public func openRecordingsWindow() {
        openWindow?(AppWindowPresenter.recordingsWindowID)
    }

    /// Stops audio capture and waits for its final tail and publication work.
    public func stopAudioRecording() async -> AudioRecordingResult {
        let result = await recordingSessionController.stopAudio()
        AudioRecordingMenuState.clear()
        return result
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
                message: AppLocalization.string("The audio source could not be changed; the current source is unchanged."),
                type: .error
            )
        }
    }

    private func ensureMicrophonePermission(for mode: AudioSourceMode) async -> Bool {
        guard mode == .microphone || mode == .systemAndMicrophone else { return true }

        let authorizer = AVMicrophoneAuthorizer()
        let initialState = authorizer.currentState()
        var state = initialState
        switch MicrophonePermission.guidance(for: initialState) {
        case .ready:
            return true
        case .requestAccess:
            state = await authorizer.requestAccess()
        case .openSystemSettings, .useSystemAudioFallback, .ignore:
            break
        }

        guard state == .authorized else {
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

    func configureRecording() {
        recordingSessionController.onStatusChange = { [weak self] status in
            self?.recordingStatus = status
            if status == .idle {
                AudioRecordingMenuState.clear()
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
        HotKeyManager.shared.onScreenRecording = { [weak self] in
            self?.startRecording()
        }
        HotKeyManager.shared.onAudioRecording = { [weak self] in
            Task { await self?.startDefaultAudioRecording() }
        }
    }

    func refreshRecordingShelfVisibility() {
        let statusIsRecording = recordingStatus == .starting || recordingStatus == .recording || recordingStatus == .saving
        setRecordingShelfVisibility(isRecording: isAudioRecordingActive || statusIsRecording)
    }

    private func setRecordingShelfVisibility(isRecording: Bool) {
        let shouldHide = UserDefaults.standard.object(forKey: PreferenceKeys.recordingHideShelfWhileRecording) as? Bool
            ?? PreferenceDefaults.recordingHideShelfWhileRecording
        screenshotShelfManager.setRecordingActive(isRecording, hideShelf: shouldHide)
    }
}
