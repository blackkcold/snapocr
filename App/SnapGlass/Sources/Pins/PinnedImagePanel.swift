import AppKit

// MARK: - PinnedImagePanel

@MainActor
final class PinnedImagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // 决策 8：置顶内容不进入任何第三方录屏、系统截屏或后续 SnapGlass 截图。
        sharingType = .none
    }

    /// ⌘W 需经 `performKeyEquivalent` 处理。
    ///
    /// Command 组合键在无边框面板中先走 key equivalent 分发，`keyDown` 不可靠。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 13, event.modifierFlags.contains(.command) {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
            return
        }
        super.keyDown(with: event)
    }
}
