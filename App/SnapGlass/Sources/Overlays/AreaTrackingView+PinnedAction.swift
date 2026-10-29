import AppKit
import SharedKit

// MARK: - AreaTrackingView ⌘P 置顶

extension AreaTrackingView {
    var isPinShortcutPhase: Bool {
        phase == .selected
    }

    /// 选区已可调整时直接置顶；动作栏与手柄无需先经过确认态。
    func performPinShortcut() {
        completeSelection(action: .pin)
    }
}
