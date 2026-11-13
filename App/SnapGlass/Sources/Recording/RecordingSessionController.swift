import AppKit
import CaptureCore
import Foundation
import SharedKit

@preconcurrency import ScreenCaptureKit

typealias AudioPipelineFactory = @MainActor (
    AudioRecordingConfiguration,
    RecordingPipelineRoots
) throws -> RecordingSessionPipeline

private struct RecordingPreferenceSnapshot: Sendable {
    let codec: RecordingVideoCodec
    let resolutionProfile: String
    let frameRate: Int
    let averageVideoBitrate: Int
    let capturesSystemAudio: Bool
    let destinationDirectory: URL?
    let hasCustomDestination: Bool

    init(defaults: UserDefaults) {
        let storedCodec = defaults.string(forKey: PreferenceKeys.recordingVideoCodec)
            ?? PreferenceDefaults.recordingVideoCodec
        codec = RecordingVideoCodec(rawValue: storedCodec) ?? .h264
        resolutionProfile = defaults.string(forKey: PreferenceKeys.recordingResolution)
            ?? PreferenceDefaults.recordingResolution

        let storedFrameRate = (defaults.object(forKey: PreferenceKeys.recordingFrameRate) as? NSNumber)?.intValue
            ?? PreferenceDefaults.recordingFrameRate
        frameRate = [24, 30, 60].contains(storedFrameRate) ? storedFrameRate : PreferenceDefaults.recordingFrameRate

        let storedBitrate =
            (defaults.object(forKey: PreferenceKeys.recordingAverageVideoBitrate) as? NSNumber)?.intValue
            ?? PreferenceDefaults.recordingAverageVideoBitrate
        averageVideoBitrate = [2, 4, 8, 12, 16, 20].contains(storedBitrate / 1_000_000)
            ? storedBitrate
            : PreferenceDefaults.recordingAverageVideoBitrate

        capturesSystemAudio = defaults.object(forKey: PreferenceKeys.recordingSystemAudio) == nil
            ? PreferenceDefaults.recordingSystemAudio
            : defaults.bool(forKey: PreferenceKeys.recordingSystemAudio)
        destinationDirectory = RecordingDestinationPreferences.directory(in: defaults)
        hasCustomDestination = RecordingDestinationPreferences.customDirectory(in: defaults) != nil
    }

    func configuration(for selection: RecordingSourceSelection) -> RecordingConfiguration {
        let sourceDimensions = Self.pixelDimensions(for: selection)
        let resolutionLimit: CGSize
        switch resolutionProfile {
        case "720p":
            resolutionLimit = CGSize(width: 1_280, height: 720)
        case "1440p":
            resolutionLimit = CGSize(width: 2_560, height: 1_440)
        case "2160p":
            resolutionLimit = CGSize(width: 3_840, height: 2_160)
        case "source":
            resolutionLimit = sourceDimensions
        default:
            resolutionLimit = CGSize(width: 1_920, height: 1_080)
        }

        return RecordingConfiguration(
            codec: codec,
            resolutionLimit: resolutionLimit,
            frameRateLimit: frameRate,
            averageVideoBitrate: averageVideoBitrate,
            capturesSystemAudio: capturesSystemAudio
        )
    }

    private static func pixelDimensions(for selection: RecordingSourceSelection) -> CGSize {
        if case .display = selection.source {
            return selection.displayPixelSize
        }

        guard selection.displayFrame.width > 0, selection.displayFrame.height > 0 else { return .zero }
        let scaleX = selection.displayPixelSize.width / selection.displayFrame.width
        let scaleY = selection.displayPixelSize.height / selection.displayFrame.height
        return CGSize(
            width: selection.sourceFrame.width * scaleX,
            height: selection.sourceFrame.height * scaleY
        )
    }
}

private struct RecordingSessionSnapshot: Sendable {
    let selection: RecordingSourceSelection
    let configuration: RecordingConfiguration
    let destinationDirectory: URL
}

enum RecordingStorage {
    static let minimumStartFreeSpace: Int64 = 1_024 * 1_024 * 1_024
    static let minimumContinueFreeSpace: Int64 = 512 * 1_024 * 1_024

    static func availableBytes(at directory: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let availableBytes = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return availableBytes.int64Value
    }

    static func formattedBytes(_ byteCount: Int64) -> String {
        let language = UserDefaults.standard.string(forKey: PreferenceKeys.appLanguage)
            ?? PreferenceDefaults.appLanguage
        return ByteCountFormatStyle(
            style: .file,
            locale: (AppLanguage(rawValue: language) ?? .system).locale
        ).format(byteCount)
    }
}

@MainActor
final class RecordingSessionController {
    private let captureOrchestrator: CaptureOrchestrator
    let defaults: UserDefaults
    private let fileManager: FileManager
    private let pipelineRoots: RecordingPipelineRoots
    private let audioPipelineFactory: AudioPipelineFactory
    private(set) var status: RecordingSessionStatus = .idle
    private var outcomeState = RecordingSessionOutcomeState()
    var audioStateMachine = RecordingAudioSessionStateMachine()

    var onStatusChange: ((RecordingSessionStatus) -> Void)?
    var onScreenshotShelfRecordingChange: ((Bool) -> Void)?
    var onMessage: ((String, ToastType) -> Void)?
    var onOpenPermissionGuide: (() -> Void)?
    var onOpenRecordings: (() -> Void)?
    var onFailureChange: ((RecordingControlPanelFailure?) -> Void)?

    private var activeSession: RecordingSessionSnapshot?
    var sessionScreen: NSScreen?
    var engine: ScreenRecordingEngine?
    private var screenPipelineAdapter: ScreenRecordingPipelineAdapter?
    var controlPanel: RecordingControlPanel?
    var captureFramePanel: RecordingCaptureFramePanel?
    var recordingStartedAt: Date?
    var panelHiddenByUser = false
    var watchdogReported = false
    var retainedFailure: (engine: ScreenRecordingEngine, payload: RecordingControlPanelFailure)?
    private var countdownTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var stopWhenStarted = false
    private var pendingStopReason: String?
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var outcomeWaiters: [CheckedContinuation<RecordingSessionTerminalOutcome, Never>] = []
    private var currentStartAttemptIdentifier: UUID?
    var audioPipeline: RecordingSessionPipeline?
    var audioConfiguration: AudioRecordingConfiguration?
    var audioCurrentMode: AudioSourceMode?
    var audioSessionID: UUID?
    private var audioStartTask: Task<Void, any Error>?
    private var audioStopTask: Task<AudioRecordingResult, Never>?
    private var audioStopRequested = false
    private var audioPipelineStarted = false
    private var audioRecoveryPending = false
    var lastAudioResult: AudioRecordingResult?
    var audioProgressTask: Task<Void, Never>?
    var previewReadinessTask: Task<Void, Never>?
    var previewLoadTask: Task<Void, Never>?
    var previewService: RecordingPreviewService?
    var previewLease: PreviewLease?
    var previewTarget: PreviewTarget?
    var previewPlayer: RecordingAudioPreviewPlayer?
    var previewReleaseTask: Task<Void, Never>?
    var previewReleaseGeneration = 0
    var previewLifecycleGeneration = 0
    var audioProgress: RecordingProgress?
    var latestAudioOutputURL: URL?
    var audioHUDExpanded = false
    var audioSilenceStartedAt: ContinuousClock.Instant?
    var audioSilenceWarningShown = false
    var audioSilenceWarningVisible = false

    var isBusy: Bool { status.isBusy }
    var needsQuitConfirmation: Bool { status.needsQuitConfirmation }
    var isSaving: Bool { status == .saving || hasPendingBackgroundFinalization }
    var terminalOutcome: RecordingSessionTerminalOutcome? { outcomeState.terminalOutcome }
    var isAudioSessionActive: Bool {
        switch audioStateMachine.state {
        case .starting, .recording, .stopping, .finalizing: true
        case .idle, .finished, .failedRecoverable: false
        }
    }
    var hasPendingBackgroundFinalization: Bool {
        audioStopRequested || audioStopTask != nil || audioStateMachine.state == .finalizing || audioRecoveryPending
    }

    init(
        captureOrchestrator: CaptureOrchestrator,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        pipelineRoots: RecordingPipelineRoots,
        audioPipelineFactory: @escaping AudioPipelineFactory
    ) {
        self.captureOrchestrator = captureOrchestrator
        self.defaults = defaults
        self.fileManager = fileManager
        self.pipelineRoots = pipelineRoots
        self.audioPipelineFactory = audioPipelineFactory
        installLifecycleObservers()
    }

    func cancelPendingStart() {
        switch status {
        case .selectingSource:
            finishSession(success: false)
            RecordingSourcePickerPanel.cancelActivePanel()
            AreaSelectionPanel.cancelRecordingRegionSelection()
        case .countdown:
            countdownTask?.cancel()
            finishSession(success: false)
        case .idle, .starting, .recording, .saving:
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
            return await waitForStopCompletion()
        case .recording:
            return await finalizeRecording(reason: reason)
        case .saving:
            return await waitForStopCompletion()
        }
    }

    func stopAndResolveForQuit(reason: String) async -> RecordingSessionTerminalOutcome {
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
        if outcome.allowsApplicationQuit { await closeAudioPreview() }
        return outcome
    }

    /// Starts the audio pipeline after the app has resolved the required system permission.
    /// This method never requests microphone permission itself.
    func startAudio(_ configuration: AudioRecordingConfiguration) async throws {
        guard status == .idle, !isAudioSessionActive, !hasPendingBackgroundFinalization else {
            throw RecordingPipelineError.alreadyStarted
        }

        await closeAudioPreview()
        audioProgressTask?.cancel()
        audioProgressTask = nil
        previewReadinessTask?.cancel()
        previewReadinessTask = nil
        audioProgress = nil
        audioCurrentMode = configuration.mode
        latestAudioOutputURL = nil
        audioHUDExpanded = false
        audioSilenceStartedAt = nil
        audioSilenceWarningShown = false
        audioSilenceWarningVisible = false
        panelHiddenByUser = false

        outcomeState.beginSession()
        audioStateMachine = RecordingAudioSessionStateMachine()
        audioStateMachine.apply(.begin)
        audioConfiguration = configuration
        audioSessionID = UUID()
        audioPipelineStarted = false
        audioRecoveryPending = false
        audioStopRequested = false
        lastAudioResult = nil
        updateStatus(audioStateMachine.legacyStatus)

        let pipeline: RecordingSessionPipeline
        do {
            pipeline = try audioPipelineFactory(configuration, pipelineRootsForCurrentDestination())
        } catch {
            completeAudioSession(with: failedAudioResult(error))
            throw error
        }

        audioPipeline = pipeline
        audioSessionID = pipeline.ledger.sessionID
        let task = Task { try await pipeline.start(configuration) }
        audioStartTask = task
        do {
            try await task.value
            audioStartTask = nil
            markAudioPipelineStarted()
            if audioStopRequested {
                _ = await stopAudio()
            }
        } catch {
            audioStartTask = nil
            completeAudioSession(with: failedAudioResult(error))
            throw error
        }
    }

    /// Stops capture idempotently and returns only after T9 has drained tail and seal work.
    func stopAudio() async -> AudioRecordingResult {
        if let audioStopTask { return await audioStopTask.value }
        if audioRecoveryPending, let lastAudioResult { return lastAudioResult }
        if !isAudioSessionActive && !hasPendingBackgroundFinalization {
            return lastAudioResult ?? makeAudioResult(failure: "recording pipeline is not active")
        }

        if let audioStartTask {
            audioStopRequested = true
            audioStateMachine.apply(.stopRequested)
            updateStatus(audioStateMachine.legacyStatus)
            do {
                try await audioStartTask.value
                markAudioPipelineStarted()
            } catch {
                if let lastAudioResult { return lastAudioResult }
                let result = failedAudioResult(error)
                completeAudioSession(with: result)
                return result
            }
        }

        if let audioStopTask { return await audioStopTask.value }
        guard let pipeline = audioPipeline else {
            let result = lastAudioResult ?? makeAudioResult(failure: "recording pipeline is unavailable")
            completeAudioSession(with: result)
            return result
        }

        audioStopRequested = true
        audioStateMachine.apply(.stopRequested)
        audioStateMachine.beginFinalization()
        updateStatus(audioStateMachine.legacyStatus)

        await beginPreviewReadinessMonitoring(for: pipeline)

        let task = Task { @MainActor [weak self] in
            let result = await pipeline.stop()
            let outputURL = await pipeline.latestPublishedFileURL()
            await self?.previewReadinessTask?.value
            self?.completeAudioSession(with: result, outputURL: outputURL)
            return result
        }
        audioStopTask = task
        return await task.value
    }

    func applyRoute(_ event: RouteEvent) async -> RouteCommitResult {
        guard let audioPipeline else {
            return .unchanged(reason: "recording pipeline is not active")
        }
        let result = await audioPipeline.applyRoute(event)
        if case .committed = result { audioCurrentMode = event.mode }
        return result
    }

    func makeAudioProgressStream() -> AsyncStream<RecordingProgress> {
        guard let audioPipeline else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return audioPipeline.makeProgressStream()
    }

    func waitForBackgroundFinalization() async -> RecordingSessionTerminalOutcome {
        if let audioStopTask {
            _ = await audioStopTask.value
            return outcomeState.terminalOutcome ?? .failed
        }
        if audioStopRequested {
            _ = await stopAudio()
            return outcomeState.terminalOutcome ?? .failed
        }
        if isAudioSessionActive { return .failed }
        return outcomeState.terminalOutcome ?? .noActiveSession
    }

    private func pipelineRootsForCurrentDestination() -> RecordingPipelineRoots {
        guard let destination = RecordingDestinationPreferences.directory(in: defaults) else {
            return pipelineRoots
        }
        let outputDirectory = destination.standardizedFileURL
        let sessionsDirectory = outputDirectory.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        return RecordingPipelineRoots(
            sessionRoot: outputDirectory,
            indexURL: sessionsDirectory.appendingPathComponent("recording-index.json"),
            outputDirectory: outputDirectory
        )
    }

    private func pipelineRoots(for directory: URL) -> RecordingPipelineRoots {
        let outputDirectory = directory.standardizedFileURL
        let sessionsDirectory = outputDirectory.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        return RecordingPipelineRoots(
            sessionRoot: outputDirectory,
            indexURL: sessionsDirectory.appendingPathComponent("recording-index.json"),
            outputDirectory: outputDirectory
        )
    }

    private func markAudioPipelineStarted() {
        guard !audioPipelineStarted else { return }
        audioPipelineStarted = true
        outcomeState.markRecordingStarted()
        guard !audioStopRequested else { return }
        audioStateMachine.apply(.started)
        recordingStartedAt = Date()
        if let audioPipeline { startAudioProgressMonitoring(for: audioPipeline) }
        updateStatus(audioStateMachine.legacyStatus)
        presentAudioRecordingHUD()
    }

    private func failedAudioResult(_ error: Error) -> AudioRecordingResult {
        makeAudioResult(failure: String(describing: error))
    }

    private func makeAudioResult(failure: String?) -> AudioRecordingResult {
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

    private func completeAudioSession(with result: AudioRecordingResult, outputURL: URL? = nil) {
        guard lastAudioResult == nil else { return }
        lastAudioResult = result
        latestAudioOutputURL = outputURL
        audioProgressTask?.cancel()
        audioProgressTask = nil
        audioStartTask = nil
        audioStopTask = nil
        audioStopRequested = false
        let saved = Self.audioResultWasSaved(result)
        audioRecoveryPending = !saved && audioPipelineStarted
        if saved {
            audioStateMachine.apply(.stopCompleted(saved: true))
        } else {
            audioStateMachine.apply(.stopCompleted(saved: false))
            audioStateMachine.apply(.failedRecoverable)
        }
        outcomeState.finishSession(wasSaved: saved)
        updateStatus(audioStateMachine.legacyStatus)
        if result.segmentCount > 0, !panelHiddenByUser, !RecordingHUDPreferences.isHidden(in: defaults) {
            if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
            controlPanel?.present(state: .audioFinished(
                savedSegments: result.segmentCount,
                outputURL: outputURL,
                previewReady: previewLease != nil,
                previewPlaying: previewPlayer?.isPlaying ?? false
            ))
        }
    }

    private static func audioResultWasSaved(_ result: AudioRecordingResult) -> Bool {
        result.failure == nil && result.segmentCount > 0
    }

    private func sourcePickerCompleted(
        _ selection: RecordingSourceSelection?,
        preferences: RecordingPreferenceSnapshot,
        attemptIdentifier: UUID
    ) {
        guard currentStartAttemptIdentifier == attemptIdentifier,
              status == .selectingSource else { return }
        guard let selection else {
            finishSession(success: false)
            return
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
            try prepareDestination(destination, isCustom: preferences.hasCustomDestination)
        } catch {
            let message = AppLocalization.string(
                "Unable to start recording: %@",
                AppLocalization.recordingErrorDescription(error)
            )
            onMessage?(message, .error)
            finishSession(success: false)
            return
        }

        activeSession = RecordingSessionSnapshot(
            selection: selection,
            configuration: configuration,
            destinationDirectory: destination
        )
        beginCountdown(for: selection)
    }

    private func prepareDestination(_ directory: URL, isCustom: Bool) throws {
        var isDirectory = ObjCBool(false)
        if isCustom {
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.isWritableFile(atPath: directory.path) else {
                throw RecordingDestinationError.customDirectoryUnavailable
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        guard let availableBytes = RecordingStorage.availableBytes(at: directory) else {
            throw RecordingDestinationError.unavailableCapacity
        }
        guard availableBytes >= RecordingStorage.minimumStartFreeSpace else {
            throw RecordingDestinationError.insufficientCapacity
        }
    }

    private func beginCountdown(for selection: RecordingSourceSelection) {
        let screen = screen(for: selection.displayID)
        sessionScreen = screen
        let panel = makeControlPanel(on: screen)
        controlPanel = panel
        if !RecordingHUDPreferences.isHidden(in: defaults) {
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
        guard status.isBusy, let activeSession else { return }
        updateStatus(.starting)

        let engine = ScreenRecordingEngine()
        self.engine = engine
        screenPipelineAdapter = nil
        RecordingWindowExclusionRegistry.shared.onChange = { [weak engine] windowIDs in
            guard let engine else { return }
            Task { await engine.updateExcludedWindowIDs(windowIDs) }
        }
        do {
            let coordinator = try ScreenRecordingSessionCoordinator.makeProduction(
                engine: engine,
                roots: pipelineRoots(for: activeSession.destinationDirectory)
            )
            let adapter = ScreenRecordingPipelineAdapter(coordinator: coordinator)
            let screenMode = RecordingAudioPreferenceStore.mode(for: .screen, in: defaults)
            let storedBitRate = defaults.object(forKey: RecordingAudioPreferenceStore.audioBitRateKey) as? Int
                ?? 128_000
            let audioBitRate = [96_000, 128_000, 192_000, 256_000].contains(storedBitRate)
                ? storedBitRate
                : 128_000
            let startConfiguration = ScreenRecordingPipelineAdapter.makeStartConfiguration(
                source: activeSession.selection.source,
                video: activeSession.configuration,
                audioMode: screenMode,
                audioBitRate: audioBitRate,
                destinationDirectory: activeSession.destinationDirectory,
                excludedWindowIDs: excludedWindowIDs,
                sourceDimensions: screenSourceDimensions(for: activeSession.selection)
            )
            screenPipelineAdapter = adapter
            try await adapter.start(
                startConfiguration,
                onFailure: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        _ = await self.stopAndSave()
                    }
                }
            )
            outcomeState.markRecordingStarted()
            updateStatus(.recording)
            if stopWhenStarted {
                _ = await finalizeRecording(reason: pendingStopReason)
            } else {
                startMonitoring()
            }
        } catch {
            screenPipelineAdapter = nil
            let message = AppLocalization.string(
                "Unable to start recording: %@",
                AppLocalization.recordingErrorDescription(error)
            )
            onMessage?(message, .error)
            finishSession(success: false)
        }
    }

    private func finalizeRecording(reason: String?) async -> Bool {
        guard status == .recording, let engine else { return false }
        monitoringTask?.cancel()
        monitoringTask = nil
        updateStatus(.saving)

        do {
            let finalURL: URL
            if let screenPipelineAdapter {
                let outcome = try await screenPipelineAdapter.stopAndSave()
                guard outcome.isSaved, let latestURL = outcome.latestPublishedURL else {
                    throw ScreenRecordingEngineError.finalizationFailed(
                        outcome.failure ?? "The screen recording did not publish a video segment.",
                        partialURL: await engine.partialOutputURL
                    )
                }
                finalURL = latestURL
                self.screenPipelineAdapter = nil
            } else {
                finalURL = try await engine.stopAndSave()
            }
            let message: String
            if let reason {
                message = AppLocalization.string(
                    "Recording stopped and saved (%@): %@",
                    reason,
                    finalURL.lastPathComponent
                )
            } else {
                message = AppLocalization.string("Recording saved: %@", finalURL.lastPathComponent)
            }
            onMessage?(message, .success)
            finishSession(success: true)
            if RecordingHUDPreferences.revealsOnFinish(in: defaults) {
                revealInFinder(finalURL)
            }
            return true
        } catch {
            await handleRecordingFailure(error, engine: engine)
            return false
        }
    }

    private func screenSourceDimensions(for selection: RecordingSourceSelection) -> CGSize {
        if case .display = selection.source { return selection.displayPixelSize }
        guard selection.displayFrame.width > 0, selection.displayFrame.height > 0 else {
            return selection.displayPixelSize
        }
        let scaleX = selection.displayPixelSize.width / selection.displayFrame.width
        let scaleY = selection.displayPixelSize.height / selection.displayFrame.height
        return CGSize(
            width: selection.sourceFrame.width * scaleX,
            height: selection.sourceFrame.height * scaleY
        )
    }

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, self.status == .recording else { return }
                await self.reportMissingFramesIfNeeded()
                if let reason = await self.recordingInterruptionReason() {
                    _ = await self.stopAndSave(reason: reason)
                    return
                }
            }
        }
    }

    private func recordingInterruptionReason() async -> String? {
        guard let activeSession else { return nil }
        guard let availableBytes = RecordingStorage.availableBytes(at: activeSession.destinationDirectory) else {
            return AppLocalization.string("The recording destination is no longer available.")
        }
        guard availableBytes >= RecordingStorage.minimumContinueFreeSpace else {
            return AppLocalization.string("Free space fell below 512 MB; the recording is being finalized.")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            // Rare failure path: this poll ends the recording anyway, so fall
            // back to the existing check to keep both messages (permission lost
            // vs. source unavailable) and the permission guide exactly as today.
            guard await captureOrchestrator.checkPermissionStatus() else {
                onOpenPermissionGuide?()
                return AppLocalization.string(
                    "Screen recording permission was lost; the recording is being finalized."
                )
            }
            return AppLocalization.string(
                "Recording sources are no longer available; the recording is being finalized."
            )
        }

        // Steady state: one enumeration answers both permission and source changes.
        guard await captureOrchestrator.checkPermissionStatus(displayCount: content.displays.count) else {
            onOpenPermissionGuide?()
            return AppLocalization.string(
                "Screen recording permission was lost; the recording is being finalized."
            )
        }
        return Self.sourceChangeReason(for: activeSession.selection, in: content)
    }

    private static func sourceChangeReason(
        for selection: RecordingSourceSelection,
        in content: SCShareableContent
    ) -> String? {
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            return AppLocalization.string("The selected display was disconnected; the recording is being finalized.")
        }
        guard display.width == Int(selection.displayPixelSize.width),
              display.height == Int(selection.displayPixelSize.height),
              display.frame.size == selection.displayFrame.size else {
            return AppLocalization.string("The selected display changed size; the recording is being finalized.")
        }

        switch selection.source {
        case .display, .region:
            return nil
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return AppLocalization.string(
                    "The selected window is no longer available; the recording is being finalized."
                )
            }
            guard window.frame.size == selection.sourceFrame.size,
                  display.frame.contains(window.frame) else {
                return AppLocalization.string(
                    "The selected window changed size or display; the recording is being finalized."
                )
            }
            return nil
        }
    }

    private func handleInterruption(_ reason: String) async {
        switch status {
        case .idle:
            return
        case .selectingSource, .countdown:
            cancelPendingStart()
            onMessage?(reason, .info)
        case .starting, .recording, .saving:
            _ = await stopAndSave(reason: reason)
        }
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleInterruption(AppLocalization.string("The Mac is going to sleep."))
            }
        })

        notificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hasPendingBackgroundFinalization {
                    _ = await self.waitForBackgroundFinalization()
                } else if self.isAudioSessionActive {
                    // If sleep suspended the notification task before it requested a stop, resume
                    // through the same pipeline/ledger finalizer instead of claiming the session saved.
                    _ = await self.stopAudio()
                }
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.status == .recording || self.status == .starting else { return }
                await self.handleInterruptionIfSourceChanged()
            }
        })

        let distributedCenter = DistributedNotificationCenter.default()
        notificationObservers.append(distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Audio capture is allowed to continue through a lock; sleep still requests a
                // durable stop above. Preserve the existing screen-recording interruption path.
                guard let self, !self.isAudioSessionActive, !self.hasPendingBackgroundFinalization else {
                    return
                }
                await self.handleInterruption(AppLocalization.string("The screen was locked."))
            }
        })
    }

    private func handleInterruptionIfSourceChanged() async {
        guard let activeSession else { return }
        do {
            let content = try await SCShareableContent.current
            if let reason = Self.sourceChangeReason(for: activeSession.selection, in: content) {
                await handleInterruption(reason)
            }
        } catch {
            await handleInterruption(
                AppLocalization.string("Recording sources are no longer available; the recording is being finalized.")
            )
        }
    }

    func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == displayID
        }
    }

    private var isCountingDown: Bool {
        if case .countdown = status { return true }
        return false
    }

    private func updateStatus(_ status: RecordingSessionStatus) {
        self.status = status
        onStatusChange?(status)
        guard !panelHiddenByUser else { return }
        switch status {
        case .countdown(let seconds):
            controlPanel?.update(state: .countdown(seconds))
        case .starting:
            if audioStateMachine.state == .starting {
                if controlPanel == nil { controlPanel = makeControlPanel(on: NSScreen.main) }
                controlPanel?.present(state: .starting)
                return
            }
            controlPanel?.update(state: .starting)
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
            controlPanel?.update(state: .saving(fileName: nil))
        case .idle, .selectingSource:
            break
        }
    }

    func finishSession(success: Bool) {
        Task { @MainActor [weak self] in await self?.closeAudioPreview() }
        outcomeState.finishSession(wasSaved: success)
        countdownTask?.cancel()
        countdownTask = nil
        monitoringTask?.cancel()
        monitoringTask = nil
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
        onScreenshotShelfRecordingChange?(false)
        updateStatus(.idle)

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

    private func waitForStopCompletion() async -> Bool {
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    private func waitForTerminalOutcome() async -> RecordingSessionTerminalOutcome {
        await withCheckedContinuation { continuation in
            outcomeWaiters.append(continuation)
        }
    }
}

extension RecordingSessionController {
    func startRecording() {
        guard status == .idle else { return }
        dismissFailurePanel()
        outcomeState.beginSession()
        let attemptIdentifier = UUID()
        currentStartAttemptIdentifier = attemptIdentifier
        let preferences = RecordingPreferenceSnapshot(defaults: defaults)
        onScreenshotShelfRecordingChange?(true)
        updateStatus(.selectingSource)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let accessAvailable = await self.captureOrchestrator.checkPermissionStatus()
            let decision = RecordingPermissionDecision.beforePicker(
                accessAvailable: accessAvailable,
                isCurrentAttempt: self.currentStartAttemptIdentifier == attemptIdentifier,
                isSelectingSource: self.status == .selectingSource
            )

            switch decision {
            case .showPicker:
                self.showSourcePicker(for: attemptIdentifier, preferences: preferences)
            case .openPermissionGuide:
                self.finishSession(success: false)
                self.onOpenPermissionGuide?()
            case .showPickerFailure, .ignore:
                return
            }
        }
    }

    private func showSourcePicker(
        for attemptIdentifier: UUID,
        preferences: RecordingPreferenceSnapshot
    ) {
        RecordingSourcePickerPanel.show(
            onComplete: { [weak self] selection in
                Task { @MainActor [weak self] in
                    self?.sourcePickerCompleted(
                        selection,
                        preferences: preferences,
                        attemptIdentifier: attemptIdentifier
                    )
                }
            },
            onFailure: { [weak self] message in
                let failedAttemptIdentifier = attemptIdentifier
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let accessAvailable = await self.captureOrchestrator.checkPermissionStatus()
                    let decision = RecordingPermissionDecision.afterPickerFailure(
                        accessAvailable: accessAvailable,
                        isCurrentAttempt: self.currentStartAttemptIdentifier == failedAttemptIdentifier
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

private enum RecordingDestinationError: LocalizedError {
    case customDirectoryUnavailable
    case unavailableCapacity
    case insufficientCapacity

    var errorDescription: String? {
        switch self {
        case .customDirectoryUnavailable:
            AppLocalization.string("The selected recording folder is unavailable. Choose it again in Preferences.")
        case .unavailableCapacity:
            AppLocalization.string("Could not check free space in the recording folder.")
        case .insufficientCapacity:
            AppLocalization.string("At least 1 GB of free space is required to start recording.")
        }
    }
}
