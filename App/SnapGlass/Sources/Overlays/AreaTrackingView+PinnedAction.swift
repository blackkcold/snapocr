import AppKit
import SharedKit

// MARK: - AreaTrackingView ⌘P 置顶

extension AreaTrackingView {
    var isPinShortcutPhase: Bool {
        phase == .adjusting || phase == .choosingAction
    }

    /// Dispatches to the phase-specific pin path.
    ///
    /// `.choosingAction` must go through `completeSelection`, which requires that
    /// phase; submitting the selection directly would silently do nothing.
    func performPinShortcut() {
        switch phase {
        case .adjusting:
            guard selectionRect.width > 5, selectionRect.height > 5 else { return }
            onSelectionComplete?(makeSelectionResult(action: .pin))
        case .choosingAction:
            completeSelection(action: .pin)
        case .idle, .drawing:
            return
        }
    }
}
