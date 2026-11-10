import AppKit
import SwiftUI

@MainActor
final class ScreenshotShelfPanel: NSPanel {
    let hostingView: ShelfHostingView
    /// Installed by the manager once the drag export store exists.
    var dragOutController: ScreenshotShelfDragOutController?

    init(contentRect: CGRect, model: ScreenshotShelfViewModel) {
        hostingView = ShelfHostingView(rootView: ScreenshotShelfView(model: model))
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
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        sharingType = .none
        acceptsMouseMovedEvents = true
        contentView = hostingView
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Routes pointer events through the drag-out controller before SwiftUI sees them.
    ///
    /// A window keeps receiving `leftMouseDragged` after mouse-down even when the
    /// pointer leaves its bounds, which is what lets an in-shelf reorder become a
    /// system file drag mid-gesture.
    override func sendEvent(_ event: NSEvent) {
        if dragOutController?.handle(event) == true {
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        assertSharingType()
    }

    /// Borderless shelf windows must be able to start and end a slide just outside the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Re-assert capture exclusion after every ordering operation.
    func assertSharingType() {
        if sharingType != .none {
            sharingType = .none
        }
    }

    func prepareForDisplay() {
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
    }
}

/// Hosting view that owns native pointer tracking and limits mouse handling to the shelf band.
///
/// AppKit cannot forward a click through a transparent window region, but returning `nil` from
/// `hitTest` at least keeps the transparent shadow margins from swallowing shelf interactions.
/// A native `.activeAlways` tracking area is the source of truth for hover because SwiftUI
/// `onHover` is unreliable on a non-key accessory panel.
final class ShelfHostingView: NSHostingView<ScreenshotShelfView> {
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .activeAlways,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        rootView.model.setPointerInside(true)
        updatePointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        rootView.model.setPointerInside(false)
        rootView.model.setPointerLocation(nil)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updatePointer(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = swiftUIPoint(from: point)
        let layout = rootView.model.layout
        if layout.mode == .collapsed {
            guard bounds.contains(localPoint) else { return nil }
            return super.hitTest(point)
        }
        guard interactiveRect.contains(localPoint) else { return nil }
        return super.hitTest(point)
    }

    private func updatePointer(with event: NSEvent) {
        let point = swiftUIPoint(fromWindow: event.locationInWindow)
        rootView.model.setPointerLocation(point)

        let layout = rootView.model.layout
        if layout.mode == .collapsed {
            NSCursor.pointingHand.set()
        } else if cardBand.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func swiftUIPoint(from point: NSPoint) -> CGPoint {
        var local = convert(point, from: superview)
        if !isFlipped {
            local.y = bounds.height - local.y
        }
        return local
    }

    private func swiftUIPoint(fromWindow point: NSPoint) -> CGPoint {
        var local = convert(point, from: nil)
        if !isFlipped {
            local.y = bounds.height - local.y
        }
        return local
    }

    private var cardBand: CGRect {
        let layout = rootView.model.layout
        guard layout.panelSize.width > 0, layout.panelSize.height > 0 else {
            return bounds
        }
        let metrics = layout.metrics
        let width = layout.panelSize.width - metrics.shadowInset * 2
        return CGRect(
            x: metrics.shadowInset,
            y: layout.cardTopOffset,
            width: max(0, width),
            height: max(0, layout.cardHeight)
        )
    }

    private var interactiveRect: CGRect {
        let layout = rootView.model.layout
        guard layout.panelSize.width > 0, layout.panelSize.height > 0 else {
            return bounds
        }
        let metrics = layout.metrics
        let width = layout.panelSize.width - metrics.shadowInset * 2
        let height = metrics.cardTopOffset + layout.cardHeight
        return CGRect(
            x: metrics.shadowInset,
            y: metrics.topInset,
            width: max(0, width),
            height: max(0, height)
        )
    }
}
