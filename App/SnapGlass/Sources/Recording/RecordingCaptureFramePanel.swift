import AppKit
import SharedKit
import SwiftUI

private struct RecordingCaptureFrameView: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color.red.opacity(0.75), lineWidth: 1.5)
            .allowsHitTesting(false)
    }
}

/// Click-through frame that marks the captured area for the duration of a recording.
///
/// The window is excluded from its own capture through `excludedWindowIDs`; the red frame is a
/// non-interactive affordance, so the user always knows which area is being recorded even when the
/// control panel is faded or hidden.
@MainActor
final class RecordingCaptureFramePanel: NSPanel {
    var excludedWindowIDs: Set<CGWindowID> {
        guard windowNumber > 0 else { return [] }
        return [CGWindowID(windowNumber)]
    }

    init(rect: CGRect) {
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        contentView = NSHostingView(rootView: RecordingCaptureFrameView())
        setFrame(rect, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
    }

    func present() {
        orderFrontRegardless()
    }

    func update(rect: CGRect) {
        guard frame != rect else { return }
        setFrame(rect, display: true)
    }

    func dismiss() {
        orderOut(nil)
    }
}
