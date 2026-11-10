import SwiftUI
import KeyboardShortcuts
import SharedKit

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var viewModel: CaptureViewModel
    @EnvironmentObject private var router: PreferencesRouter
    
    var body: some View {
        if viewModel.isCapturing {
            Text("Capturing…")
            Divider()
        }

        Button("Area Capture") {
            viewModel.captureArea()
        }
        .globalKeyboardShortcut(.captureArea)
        .disabled(viewModel.isCapturing || viewModel.isRecordingBusy || viewModel.isScrollCaptureActive)

        Button("Window Capture") {
            viewModel.captureWindow()
        }
        .globalKeyboardShortcut(.captureWindow)
        .disabled(viewModel.isCapturing || viewModel.isRecordingBusy || viewModel.isScrollCaptureActive)

        Button("Fullscreen Capture") {
            viewModel.captureFullscreen()
        }
        .globalKeyboardShortcut(.captureFullscreen)
        .disabled(viewModel.isCapturing || viewModel.isRecordingBusy || viewModel.isScrollCaptureActive)

        Divider()

        Button(viewModel.isScreenshotShelfVisible ? "Hide Screenshot Shelf" : "Show Screenshot Shelf") {
            viewModel.toggleScreenshotShelf()
        }
        .globalKeyboardShortcut(.screenshotShelf)
        .disabled(!viewModel.canToggleScreenshotShelf)

        recordingAction

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
            // The result is rendered in the Updates settings page. Opening it
            // first keeps the menu-bar action useful even when the 30-second
            // lookup outlives the menu (or the user's attention).
            router.presentUpdates()
            viewModel.checkForUpdates()
        }

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
            Button("Stop and Save") {
                Task { _ = await viewModel.stopRecordingAndSave() }
            }
        case .saving:
            Text("Saving Recording…")
        }
    }
}
