import CaptureCore
import Foundation
import KeyboardShortcuts
import SharedKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var viewModel: CaptureViewModel
    @EnvironmentObject private var router: PreferencesRouter
    @EnvironmentObject private var updater: UpdaterManager
    @EnvironmentObject private var onboarding: OnboardingRuntime

    var body: some View {
        if let update = updater.availableUpdate {
            Button {
                updater.presentUpdate()
            } label: {
                Label(
                    AppLocalization.string("Update to %@", update.displayVersion),
                    systemImage: "arrow.down.circle.fill"
                )
            }
            Divider()
        }

        if viewModel.isCapturing {
            Text("Capturing…")
            Divider()
        }

        Button("Area Capture") {
            viewModel.captureArea()
        }
        .globalKeyboardShortcut(.captureArea)
        .disabled(viewModel.isCapturing || viewModel.isScrollCaptureActive)

        Button("Window Capture") {
            viewModel.captureWindow()
        }
        .globalKeyboardShortcut(.captureWindow)
        .disabled(viewModel.isCapturing || viewModel.isScrollCaptureActive)

        Button("Fullscreen Capture") {
            viewModel.captureFullscreen()
        }
        .globalKeyboardShortcut(.captureFullscreen)
        .disabled(viewModel.isCapturing || viewModel.isScrollCaptureActive)

        Button("All Displays Capture") {
            viewModel.captureAllDisplays()
        }
        .disabled(viewModel.isCapturing || viewModel.isScrollCaptureActive)

        Button("All Displays (One per Display)") {
            viewModel.captureEachDisplay()
        }
        .disabled(viewModel.isCapturing || viewModel.isScrollCaptureActive)

        Divider()

        Button(viewModel.isScreenshotShelfVisible ? "Hide Screenshot Shelf" : "Show Screenshot Shelf") {
            viewModel.toggleScreenshotShelf()
        }
        .globalKeyboardShortcut(.screenshotShelf)
        .disabled(!viewModel.canToggleScreenshotShelf)

        recordingAction
        audioSourceMenu

        if viewModel.isScrollCaptureActive {
            Button {
                viewModel.captureNextScrollFrame()
            } label: {
                Text("Capture Next Scroll Frame (\(viewModel.scrollCapturedFrameCount))")
            }
            .disabled(viewModel.isCapturing)

            Button("Finish Scrolling Capture") {
                viewModel.finishScrollCapture()
            }
            .disabled(viewModel.scrollCapturedFrameCount < 2 || viewModel.isCapturing)

            Button("Cancel Scrolling Capture", role: .destructive) {
                viewModel.cancelScrollCapture()
            }
        }

        Divider()

        Button("OCR from Clipboard") {
            viewModel.ocrFromClipboard()
        }
        .globalKeyboardShortcut(.ocrFromClipboard)

        Divider()

        Button("History") {
            AppWindowPresenter.present(id: "history") {
                openWindow(id: "history")
            }
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        Button("Preferences...") {
            AppWindowPresenter.present(id: "preferences") {
                openWindow(id: "preferences")
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        // "Where is it?" is a question about location, not a request to re-read the
        // guide: the coach answers it without claiming onboarding is unfinished.
        Button("Where is SnapGlass?") {
            onboarding.showCoach()
        }

        Divider()

        MenuBarTipsSection(
            tip: onboarding.menuTip,
            argument: onboarding.areaShortcutLabel,
            onAct: { tip in
                perform(tip)
            },
            onShowGuide: {
                // A replay, not a reset: the completion marker stays so the next launch
                // still treats this user as onboarded.
                onboarding.replayGuide()
            }
        )

        Divider()

        // On a first run the permission window is suppressed so it cannot appear on
        // top of the guide; this row is how the user grants later.
        Button("Screen Recording Permission…") {
            AppWindowPresenter.present(id: "permission") {
                openWindow(id: "permission")
            }
        }

        Button("Check for Updates...") {
            updater.presentUpdate()
        }
        .disabled(updater.state.isChecking)

        Divider()

        Button("Quit SnapGlass") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var recordingAction: some View {
        switch viewModel.recordingStatus {
        case .idle:
            Button("Start Audio Recording") {
                Task { await viewModel.startDefaultAudioRecording() }
            }
            .disabled(!viewModel.canStartRecording)

            Button("Start Screen Recording") {
                viewModel.startRecording()
            }
            .globalKeyboardShortcut(.screenRecording)
            .disabled(!viewModel.canStartRecording)
        case .selectingSource:
            Button("Cancel Recording Setup") {
                viewModel.cancelPendingRecordingStart()
            }
        case .countdown:
            Button("Cancel Recording Countdown") {
                viewModel.cancelPendingRecordingStart()
            }
        case .starting, .recording:
            if viewModel.isAudioRecordingActive {
                audioStopAction
            } else {
                screenStopAction
            }
        case .saving:
            if viewModel.currentRecordingKind == .audio {
                Text("Saving audio recording")
            } else {
                Text("Saving screen recording")
            }
        }
    }

    private var audioStopAction: some View {
        Button {
            Task { _ = await viewModel.stopAudioRecording() }
        } label: {
            // The menu-bar scene is rendered by ControlCenter outside the app's
            // window; a `TimelineView` here subscribes the remote scene to a
            // per-second update and can block the main thread on its fence. The
            // elapsed time is resolved when the menu is built (the menu is rebuilt
            // when it opens), which is the moment the user reads it.
            Text(
                localizedStopTitle(
                    kind: .audio,
                    duration: viewModel.audioRecordingElapsedSeconds(at: Date())
                ))
        }
        .disabled(
            !RecordingMenuModel.isEnabled(
                kind: .audio,
                isRecording: viewModel.isAudioRecordingActive,
                isSaving: viewModel.isRecordingSaving
            ))
    }

    private var screenStopAction: some View {
        Button {
            Task { _ = await viewModel.stopRecordingAndSave() }
        } label: {
            // Static for the same reason as the audio stop title above: no live
            // timeline in a ControlCenter-hosted menu scene.
            Text(localizedStopTitle(kind: .screen, duration: screenRecordingElapsed(at: Date())))
        }
        .disabled(
            !RecordingMenuModel.isEnabled(
                kind: .screen,
                isRecording: viewModel.recordingStatus == .starting || viewModel.recordingStatus == .recording,
                isSaving: viewModel.isRecordingSaving
            ))
    }

    private var audioSourceMenu: some View {
        let defaultMode = viewModel.defaultAudioRecordingMode
        let currentMode = viewModel.currentAudioRecordingMode ?? defaultMode
        let items = RecordingMenuModel.modeItems(defaultMode: defaultMode, currentMode: currentMode)
            .filter { $0.mode != .none }

        return Menu("Audio Source") {
            Section("Default for Next Recording") {
                ForEach(items, id: \.mode) { item in
                    Button {
                        viewModel.setDefaultAudioRecordingMode(item.mode)
                    } label: {
                        menuModeLabel(item, isSelected: item.isDefault)
                    }
                }
            }

            if viewModel.isAudioRecordingActive {
                Section("This Recording") {
                    ForEach(items, id: \.mode) { item in
                        Button {
                            Task { await viewModel.applyAudioSourceMode(item.mode) }
                        } label: {
                            menuModeLabel(item, isSelected: item.isCurrent)
                        }
                    }
                }
            }
        }
    }

    /// Runs a tip's action and records it as shown.
    ///
    /// The shelf tip must call `showScreenshotShelf()`, not `toggleScreenshotShelf()`:
    /// the toggle shows "Close the editor to show the screenshot shelf" while the
    /// editor is open, so the button would answer a promise with a refusal.
    ///
    /// - Parameter tip: The tip the user acted on.
    private func perform(_ tip: OnboardingTip) {
        onboarding.recordTipShown(tip.id)
        switch tip.id {
        case OnboardingTips.area.id:
            viewModel.captureArea()
        case OnboardingTips.shelf.id:
            viewModel.showScreenshotShelf()
        default:
            // Not actionable; nothing to run.
            break
        }
    }

    private func menuModeLabel(_ item: RecordingMenuModeItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .opacity(isSelected ? 1 : 0)
                .frame(width: 12)
            Text(localizedModeName(item.mode))
        }
    }

    private func localizedModeName(_ mode: AudioSourceMode) -> String {
        switch mode {
        case .system:
            AppLocalization.string("System Audio")
        case .microphone:
            AppLocalization.string("Microphone")
        case .systemAndMicrophone:
            AppLocalization.string("System Audio + Microphone")
        case .none:
            AppLocalization.string("No Audio")
        }
    }

    private func localizedStopTitle(kind: RecordingKind, duration: TimeInterval) -> String {
        let modelTitle = RecordingMenuModel.stopTitle(kind: kind, duration: duration)
        let elapsed: String
        if let opening = modelTitle.lastIndex(of: "("), let closing = modelTitle.lastIndex(of: ")"), opening < closing {
            elapsed = String(modelTitle[modelTitle.index(after: opening)..<closing])
        } else {
            elapsed = "0:00"
        }
        let key = kind == .audio ? "Stop Audio Recording (%@)" : "Stop and Save (%@)"
        return AppLocalization.string(key, elapsed)
    }

    private func screenRecordingElapsed(at date: Date) -> TimeInterval {
        guard let startedAt = viewModel.recordingSessionController.recordingStartedAt else { return 0 }
        return max(0, date.timeIntervalSince(startedAt))
    }
}
