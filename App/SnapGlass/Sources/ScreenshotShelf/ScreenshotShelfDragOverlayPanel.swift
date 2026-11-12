import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// Everything the standalone drag preview needs to render one card without clipping it to the
/// shelf panel's content-sized window.
struct ScreenshotShelfDragOverlayContent: Equatable {
    var card: ScreenshotShelfCard
    var cardWidth: CGFloat
    var cardHeight: CGFloat
    var imageOpacity: Double
    var rotation: Double
    var locale: Locale
}

@MainActor
final class ScreenshotShelfDragOverlayModel: ObservableObject {
    @Published var content: ScreenshotShelfDragOverlayContent?
}

/// The drag preview is rendered in its own borderless window. Padding leaves room for the hanger,
/// the lift scale, the tilt, and the card shadow, so no part of the preview is clipped by the
/// window's own bounds either.
struct ScreenshotShelfDragOverlayView: View {
    @ObservedObject var model: ScreenshotShelfDragOverlayModel

    static let padding: CGFloat = 44

    private var content: ScreenshotShelfDragOverlayContent? { model.content }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let content {
                ScreenshotShelfCardView(
                    card: content.card,
                    cardWidth: content.cardWidth,
                    cardHeight: content.cardHeight,
                    imageOpacity: content.imageOpacity,
                    isHovered: false,
                    isDragging: true,
                    canMoveLeft: false,
                    canMoveRight: false,
                    onOpen: {},
                    onCopy: {},
                    onPin: {},
                    onRemove: {},
                    onMoveLeft: {},
                    onMoveRight: {},
                    showsHanger: true,
                    railEmphasis: true
                )
                .scaleEffect(1.04, anchor: .top)
                .rotationEffect(
                    .degrees(content.rotation),
                    anchor: UnitPoint(
                        x: 0.5,
                        y: -ScreenshotShelfMetrics.ringCenterAboveCard / max(content.cardHeight, 1)
                    )
                )
                .offset(
                    x: Self.padding,
                    y: Self.padding + ScreenshotShelfMetrics.hangerHeight
                )
            }
        }
        .frame(
            width: (content?.cardWidth ?? 1) + Self.padding * 2,
            height: (content?.cardHeight ?? 1) + ScreenshotShelfMetrics.hangerHeight + Self.padding * 2,
            alignment: .topLeading
        )
        .environment(\.locale, content?.locale ?? .current)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Floating, non-activating companion window used only while a shelf card is being dragged.
///
/// It is a child of the shelf panel, so it always sits above it, follows it, and disappears with
/// it. A card-sized window avoids a full-screen transparent surface on every display and keeps
/// multi-display backing scales correct.
/// Owns the drag-preview window and keeps its frame in sync with the shelf's local drag state.
@MainActor
final class ScreenshotShelfDragOverlayController {
    private let viewModel: ScreenshotShelfViewModel
    private let panelProvider: @MainActor () -> ScreenshotShelfPanel?
    private let isShelfVisible: @MainActor () -> Bool
    private var panel: ScreenshotShelfDragOverlayPanel?
    private let model = ScreenshotShelfDragOverlayModel()
    private nonisolated(unsafe) var resignObserver: NSObjectProtocol?
    private nonisolated(unsafe) var spaceObserver: NSObjectProtocol?

    init(
        viewModel: ScreenshotShelfViewModel,
        panel: @escaping @MainActor () -> ScreenshotShelfPanel?,
        isShelfVisible: @escaping @MainActor () -> Bool
    ) {
        self.viewModel = viewModel
        panelProvider = panel
        self.isShelfVisible = isShelfVisible
        viewModel.onDragPreviewChanged = { [weak self] preview in
            self?.update(preview)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
    }

    func prewarm() {
        guard let shelfPanel = panelProvider() else { return }
        _ = ensurePanel(on: shelfPanel)
    }

    func cancel() {
        if viewModel.dragPreview != nil {
            viewModel.cancelLocalDrag()
            NSCursor.arrow.set()
        }
        hide()
    }

    private func update(_ preview: ScreenshotShelfDragPreview?) {
        guard let preview else {
            hide()
            return
        }
        guard isShelfVisible(),
              let shelfPanel = panelProvider(),
              let card = viewModel.layout.cards.first(where: { $0.captureID == preview.cardID }) else {
            hide()
            viewModel.cancelLocalDrag()
            return
        }

        let layout = viewModel.layout
        let localX = preview.startX + preview.translation.width
        let localY = layout.cardTopOffset + preview.translation.height
        let cardTopLeft = ScreenshotShelfGeometry.shelfScreenTopLeft(
            panelFrame: shelfPanel.frame,
            localX: localX,
            localY: localY
        )
        let padding = ScreenshotShelfDragOverlayView.padding
        let hanger = ScreenshotShelfMetrics.hangerHeight
        let frame = ScreenshotShelfGeometry.dragPreviewFrame(
            cardTopLeft: cardTopLeft,
            cardWidth: preview.width,
            cardHeight: layout.cardHeight,
            padding: padding,
            hangerHeight: hanger
        )

        let overlay = ensurePanel(on: shelfPanel)
        model.content = ScreenshotShelfDragOverlayContent(
            card: card,
            cardWidth: preview.width,
            cardHeight: layout.cardHeight,
            imageOpacity: layout.imageOpacity,
            rotation: preview.rotation,
            locale: layout.locale
        )
        if overlay.frame != frame {
            overlay.setFrame(frame, display: false)
        }
        if !overlay.isVisible {
            overlay.orderFrontRegardless()
            overlay.assertSharingType()
            overlay.prepareForDisplay()
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        model.content = nil
    }

    private func ensurePanel(on shelfPanel: ScreenshotShelfPanel) -> ScreenshotShelfDragOverlayPanel {
        if let panel {
            if panel.parent !== shelfPanel {
                panel.parent?.removeChildWindow(panel)
                shelfPanel.addChildWindow(panel, ordered: .above)
                panel.orderOut(nil)
            }
            return panel
        }
        let overlay = ScreenshotShelfDragOverlayPanel(model: model)
        shelfPanel.addChildWindow(overlay, ordered: .above)
        overlay.orderOut(nil)
        panel = overlay
        return overlay
    }
}

@MainActor
final class ScreenshotShelfDragOverlayPanel: NSPanel {
    let hostingView: NSHostingView<ScreenshotShelfDragOverlayView>

    init(model: ScreenshotShelfDragOverlayModel) {
        hostingView = NSHostingView(rootView: ScreenshotShelfDragOverlayView(model: model))
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        sharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = false
        contentView = hostingView
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        assertSharingType()
    }

    func assertSharingType() {
        let resolved: NSWindow.SharingType = ShowcaseMode.isEnabled ? .readOnly : .none
        if sharingType != resolved {
            sharingType = resolved
        }
    }

    func prepareForDisplay() {
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
    }
}
