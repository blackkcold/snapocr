import AppKit
import CaptureCore
import Foundation
import SharedKit

@preconcurrency import ScreenCaptureKit

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
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private(set) var status: RecordingSessionStatus = .idle
    private var outcomeState = RecordingSessionOutcomeState()

    var onStatusChange: ((RecordingSessionStatus) -> Void)?
    var onScreenshotShelfRecordingChange: ((Bool) -> Void)?
    var onMessage: ((String, ToastType) -> Void)?
    var onOpenPermissionGuide: (() -> Void)?

    private var activeSession: RecordingSessionSnapshot?
    private var engine: ScreenRecordingEngine?
    private var controlPanel: RecordingControlPanel?
    private var countdownTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var stopWhenStarted = false
    private var pendingStopReason: String?
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var outcomeWaiters: [CheckedContinuation<RecordingSessionTerminalOutcome, Never>] = []
    private var currentStartAttemptIdentifier: UUID?

    var isBusy: Bool { status.isBusy }
    var needsQuitConfirmation: Bool { status.needsQuitConfirmation }
    var isSaving: Bool { status == .saving }
    var terminalOutcome: RecordingSessionTerminalOutcome? { outcomeState.terminalOutcome }

    init(
        captureOrchestrator: CaptureOrchestrator,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.captureOrchestrator = captureOrchestrator
        self.defaults = defaults
        self.fileManager = fileManager
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
        switch status {
        case .idle:
            return outcomeState.terminalOutcome ?? .noActiveSession
        case .selectingSource, .countdown:
            cancelPendingStart()
            return outcomeState.terminalOutcome ?? .noActiveSession
        case .starting:
            stopWhenStarted = true
            pendingStopReason = reason
            return await waitForTerminalOutcome()
        case .recording:
            _ = await finalizeRecording(reason: reason)
            return outcomeState.terminalOutcome ?? .failed
        case .saving:
            return await waitForTerminalOutcome()
        }
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
        let panel = RecordingControlPanel(
            on: screen(for: selection.displayID),
            onCancel: { [weak self] in self?.cancelPendingStart() },
            onStop: { [weak self] in
                Task { @MainActor [weak self] in
                    _ = await self?.stopAndSave()
                }
            }
        )
        controlPanel = panel
        panel.present(state: .countdown(3))
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
        do {
            try await engine.start(
                source: activeSession.selection.source,
                configuration: activeSession.configuration,
                destinationDirectory: activeSession.destinationDirectory,
                excludedWindowIDs: controlPanel?.excludedWindowIDs ?? [],
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
            let finalURL = try await engine.stopAndSave()
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
            return true
        } catch {
            onMessage?(
                AppLocalization.string("Recording failed: %@", AppLocalization.recordingErrorDescription(error)),
                .error
            )
            finishSession(success: false)
            return false
        }
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
        guard await captureOrchestrator.checkPermissionStatus() else {
            onOpenPermissionGuide?()
            return AppLocalization.string("Screen recording permission was lost; the recording is being finalized.")
        }

        do {
            let content = try await SCShareableContent.current
            return Self.sourceChangeReason(for: activeSession.selection, in: content)
        } catch {
            return AppLocalization.string(
                "Recording sources are no longer available; the recording is being finalized."
            )
        }
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
                await self?.handleInterruption(AppLocalization.string("The screen was locked."))
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

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
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
        switch status {
        case .countdown(let seconds):
            controlPanel?.update(state: .countdown(seconds))
        case .starting:
            controlPanel?.update(state: .starting)
        case .recording:
            controlPanel?.update(state: .recording)
        case .saving:
            controlPanel?.update(state: .saving)
        case .idle, .selectingSource:
            break
        }
    }

    private func finishSession(success: Bool) {
        outcomeState.finishSession(wasSaved: success)
        countdownTask?.cancel()
        countdownTask = nil
        monitoringTask?.cancel()
        monitoringTask = nil
        controlPanel?.dismiss()
        controlPanel = nil
        engine = nil
        activeSession = nil
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
