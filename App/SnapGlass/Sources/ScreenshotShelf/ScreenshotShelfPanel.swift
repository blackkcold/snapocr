import AppKit
import SwiftUI

@MainActor
final class ScreenshotShelfPanel: NSPanel {
    private let hostingView: NSHostingView<ScreenshotShelfView>

    init(contentRect: CGRect, rootView: ScreenshotShelfView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        sharingType = .none
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        sharingType = .none
    }

    func update(rootView: ScreenshotShelfView) {
        hostingView.rootView = rootView
    }
}
