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

        Divider()

        Button("OCR from Clipboard") {
            viewModel.ocrFromClipboard()
        }
        .globalKeyboardShortcut(.ocrFromClipboard)
        
        Button("Scan Barcode") {
            viewModel.scanBarcodeFromClipboard()
        }

        Divider()
        
        Menu("Recent Captures") {
            Text("No recent captures")
                .foregroundColor(.secondary)
        }
        
        Divider()
        
        Button("History") {
            openWindow(id: "history")
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])
        
        Button("Preferences...") {
            openWindow(id: "preferences")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit SnapGlass") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        .onAppear {
            viewModel.openWindow = { id in
                openWindow(id: id)
            }
            viewModel.checkPermissionsOnLaunch()
        }
    }
}
