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
        .disabled(viewModel.isCapturing)

        Button("Window Capture") {
            viewModel.captureWindow()
        }
        .globalKeyboardShortcut(.captureWindow)
        .disabled(viewModel.isCapturing)

        Button("Fullscreen Capture") {
            viewModel.captureFullscreen()
        }
        .globalKeyboardShortcut(.captureFullscreen)
        .disabled(viewModel.isCapturing)

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
}
