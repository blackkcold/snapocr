import AppKit
import CaptureCore
import SwiftUI

// MARK: - Window Selection

extension CaptureViewModel {
    /// Shows the window picker and waits for the user's choice.
    ///
    /// The panel always finishes through its own paths (capture button, Esc,
    /// close, resigning key). The timeout below only covers the panel failing
    /// to appear at all: it closes whatever is on screen, tells the user, and
    /// releases `isCapturing` so the next hotkey press still works.
    func selectWindow() async -> WindowSelectionResult? {
        await withCheckedContinuation { continuation in
            var didResume = false
            var timeoutTask: Task<Void, Never>?
            let resumeOnce: (WindowSelectionResult?) -> Void = { result in
                guard !didResume else { return }
                didResume = true
                timeoutTask?.cancel()
                continuation.resume(returning: result)
            }

            Task { @MainActor in
                WindowSelectionPanel.show { result in
                    resumeOnce(result)
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, !didResume else { return }
                WindowSelectionPanel.closeActivePanel()
                resumeOnce(nil)
                showToast(
                    message: AppLocalization.string("Window picker timed out; please try again"),
                    type: .error
                )
            }
        }
    }
}
