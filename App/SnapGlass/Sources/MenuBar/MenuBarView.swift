import Foundation
import SwiftUI
import KeyboardShortcuts
import SharedKit
import CaptureCore

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var viewModel: CaptureViewModel
    @EnvironmentObject private var router: PreferencesRouter
    @EnvironmentObject private var updater: UpdaterManager
    
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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(localizedStopTitle(
                    kind: .audio,
                    duration: viewModel.audioRecordingElapsedSeconds(at: context.date)
                ))
            }
        }
        .disabled(!RecordingMenuModel.isEnabled(
            kind: .audio,
            isRecording: viewModel.isAudioRecordingActive,
            isSaving: viewModel.isRecordingSaving
        ))
    }

    private var screenStopAction: some View {
        Button {
            Task { _ = await viewModel.stopRecordingAndSave() }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(localizedStopTitle(kind: .screen, duration: screenRecordingElapsed(at: context.date)))
            }
        }
        .disabled(!RecordingMenuModel.isEnabled(
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
