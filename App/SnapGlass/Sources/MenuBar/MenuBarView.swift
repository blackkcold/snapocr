import SwiftUI
import KeyboardShortcuts
import SharedKit

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var viewModel: CaptureViewModel
    
    var body: some View {
        Button("Area Capture") {
            viewModel.captureArea()
        }
        .globalKeyboardShortcut(.captureArea)

        Button("Window Capture") {
            viewModel.captureWindow()
        }
        .globalKeyboardShortcut(.captureWindow)

        Button("Fullscreen Capture") {
            viewModel.captureFullscreen()
        }
        .globalKeyboardShortcut(.captureFullscreen)

        if viewModel.isScrollCaptureActive {
            Button {
                viewModel.captureNextScrollFrame()
            } label: {
                Text(String(format: String(localized: "Capture Next Scroll Frame (%d)"), viewModel.scrollCapturedFrameCount))
            }

            Button("Finish Scrolling Capture") {
                viewModel.finishScrollCapture()
            }
            .disabled(viewModel.scrollCapturedFrameCount < 2)

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

        if viewModel.isCheckingForUpdates {
            Text("Checking for Updates...")
        } else if viewModel.isDownloadingUpdate {
            Text("Downloading Update...")
        } else {
            Button("Check for Updates...") {
                viewModel.checkForUpdates()
            }
        }

        Divider()

        Button("Quit SnapGlass") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
