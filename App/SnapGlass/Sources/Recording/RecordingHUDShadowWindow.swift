import AppKit
import CaptureCore
import SharedKit

/// Draws only the capsule shadow that belongs to `RecordingControlPanel`.
///
/// macOS 26 draws a thin window edge around a borderless window's frame rectangle,
/// and AppKit produces that edge from the same `hasShadow` property that produces
/// the window shadow. The panel's frame is exactly the capsule's bounding box, so
/// the system edge reads as a square grey line cutting across the capsule's round
/// ends. The panel therefore turns the system shadow off and keeps this companion
/// window one level below it: the shadow follows the capsule, and no window-level
/// decoration is left to draw on the frame rectangle.
///
/// The window never takes a click (`ignoresMouseEvents`), so the interactive panel
/// keeps its exact capsule-sized frame and no invisible margin swallows clicks.
@MainActor
final class RecordingHUDShadowWindow: NSPanel {
    /// Room outside the capsule for the blur and the downward offset.
    static let margin: CGFloat = 20

    private let shadowView = RecordingHUDShadowView()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // One level below the panel, above ordinary windows: the capsules never
        // race for order, and the shadow can never cover its own panel.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        contentView = shadowView
    }

    /// Borderless panels must keep their exact frame near screen edges.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Frames the shadow around the panel and matches the capsule's radius.
    func follow(panelFrame: CGRect, cornerRadius: CGFloat, animated: Bool) {
        shadowView.pillCornerRadius = cornerRadius
        let target = Self.shadowFrame(for: panelFrame)
        guard frame != target else { return }
        if animated {
            animator().setFrame(target, display: false)
        } else {
            setFrame(target, display: false)
            shadowView.needsDisplay = true
        }
    }

    /// Shows the shadow without raising the app or the panel.
    func reveal() {
        // `sharingType` is per-window and can be reset by ordering.
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        if !isVisible { orderFrontRegardless() }
    }

    /// The window frame that contains the capsule shadow of one panel frame.
    static func shadowFrame(for panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: -margin, dy: -margin)
    }

    /// The capsule rectangle inside one shadow window's bounds.
    static func pillRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: margin, dy: margin)
    }
}

/// Paints a soft shadow that hugs the capsule outline.
///
/// The source is a thin ring on the capsule's edge, not a filled pill: a filled
/// source would tint the panel through its translucent surface, while a ring keeps
/// the interior clear and lets the shadow fall only outside the shape.
private final class RecordingHUDShadowView: NSView {
    var pillCornerRadius: CGFloat = RecordingHUDMetrics.cornerRadius {
        didSet {
            guard oldValue != pillCornerRadius else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let pill = RecordingHUDShadowWindow.pillRect(in: bounds)
        guard pill.width > 0, pill.height > 0 else { return }
        let radius = min(max(pillCornerRadius, 0), pill.height / 2)
        let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        path.lineWidth = 6

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        NSColor.black.withAlphaComponent(0.30).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
