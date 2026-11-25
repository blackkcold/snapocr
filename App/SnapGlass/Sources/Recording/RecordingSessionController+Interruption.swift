import AppKit
import CaptureCore
import Foundation
@preconcurrency import ScreenCaptureKit
import SharedKit

/// Sleep, wake, lock, display-change, and capacity interruptions for a live session.
extension RecordingSessionController {
    func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleInterruption(AppLocalization.string("The Mac is going to sleep."))
                }
            })

        notificationObservers.append(
            workspaceCenter.addObserver(
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

        notificationObservers.append(
            NotificationCenter.default.addObserver(
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
        notificationObservers.append(
            distributedCenter.addObserver(
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

    func handleInterruption(_ reason: String) async {
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

    func startMonitoring() {
        monitoringTask?.cancel()
        let generation = sessionGeneration
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self,
                    generation == self.sessionGeneration,
                    self.status == .recording
                else { return }
                // Renew the liveness lease before doing any work this turn. If the
                // main actor stops here, the supervisor stops and saves the session
                // instead of capturing forever behind a frozen window.
                await self.settlementSupervisor.heartbeat(generation: generation)
                await self.reportMissingFramesIfNeeded()
                guard generation == self.sessionGeneration, self.status == .recording else { return }
                if let reason = await self.recordingInterruptionReason() {
                    guard generation == self.sessionGeneration, self.status == .recording else { return }
                    _ = await self.stopAndSave(reason: reason)
                    return
                }
            }
        }
    }

    private func recordingInterruptionReason() async -> String? {
        guard let activeSession else { return nil }
        switch await RecordingDestinationProbe.capacity(
            at: activeSession.destinationDirectory,
            expectedVolumeUUID: activeSession.customVolumeUUID
        ) {
        case .capacityUnreadable:
            // A slow or unreadable volume is not a confirmed failure; skip this poll.
            return nil
        case .locationUnavailable:
            return AppLocalization.string("The recording destination is no longer available.")
        case let .available(availableBytes, _, _):
            guard availableBytes >= RecordingStorage.minimumContinueFreeSpace else {
                return AppLocalization.string("Free space fell below 512 MB; the recording is being finalized.")
            }
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

    static func sourceChangeReason(
        for selection: RecordingSourceSelection,
        in content: SCShareableContent
    ) -> String? {
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            return AppLocalization.string("The selected display was disconnected; the recording is being finalized.")
        }
        guard display.width == Int(selection.displayPixelSize.width),
            display.height == Int(selection.displayPixelSize.height),
            display.frame.size == selection.displayFrame.size
        else {
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
                display.frame.contains(window.frame)
            else {
                return AppLocalization.string(
                    "The selected window changed size or display; the recording is being finalized."
                )
            }
            return nil
        }
    }
}
