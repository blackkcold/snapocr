import CoreGraphics
import SharedKit

/// Layout constants shared by the shelf panel, its SwiftUI content, and Settings previews.
public struct ScreenshotShelfMetrics: Equatable, Sendable {
    /// Transparent room above the rail for the thread, ring, and shadow.
    public var topInset: CGFloat
    /// Vertical room reserved for the rail, thread, and ring above the card.
    public var railZone: CGFloat
    /// Gap between the rail zone and the top edge of the card.
    public var railGap: CGFloat
    /// Transparent room on the sides of the visual content for card shadows and drag scale.
    ///
    /// The bottom has its own, larger inset (`shadowBottomInset`) because the hover state
    /// tilts the card and deepens its shadow.
    public var shadowInset: CGFloat
    /// Transparent room below the card row for the hover shadow.
    ///
    /// The strongest hover state (shadow radius + y offset plus the tilted card's lowest
    /// corner) needs about 21.7 pt; 24 pt keeps the shadow fully inside the panel window.
    public var shadowBottomInset: CGFloat
    /// Distance from the visible screen edge to the visual content.
    public var screenMargin: CGFloat
    /// Horizontal gap between cards.
    public var cardSpacing: CGFloat
    /// Trailing room for the shelf action menu.
    public var endMenuWidth: CGFloat
    /// Maximum displayed card width before cropping a very wide capture.
    public var maxCardWidth: CGFloat
    /// Minimum preferred card width; the fitter may go lower on extremely narrow displays.
    public var minCardWidth: CGFloat

    /// Ring diameter shared by the rail, card hanger, and drag preview.
    public static let ringDiameter: CGFloat = 6
    /// Length of the thread between the ring and the attachment dot.
    public static let threadLength: CGFloat = 15
    /// Diameter of the dot where the thread meets the card.
    public static let attachmentDotDiameter: CGFloat = 2
    /// Total hanger height above the card's top edge.
    public static let hangerHeight: CGFloat = ringDiameter + threadLength + attachmentDotDiameter
    /// Distance from the card's top edge to the ring centre.
    public static let ringCenterAboveCard: CGFloat = hangerHeight - ringDiameter / 2
    /// Vertical offset of the rail line below `topInset`.
    public static let railLineOffset: CGFloat = 2
    /// Width of the collapsed handle window. Kept tight to the drawn handle so the
    /// always-on-top window swallows as little pointer input as possible.
    public static let collapsedHandleWidth: CGFloat = 56
    /// Height of the collapsed handle window.
    public static let collapsedHandleHeight: CGFloat = 14

    /// Card hover presentation shared by the card view and the panel geometry.
    public static let hoverTiltDegrees: Double = 2
    public static let hoverContentTiltDegrees: Double = 0.5
    public static let hoverShadowRadius: CGFloat = 12
    public static let hoverShadowYOffset: CGFloat = 5
    /// Room the strongest hover shadow needs below the card, before the safety margin.
    public static let hoverShadowBottomExtent: CGFloat = 22

    public init(
        topInset: CGFloat = 8,
        railZone: CGFloat = 16,
        railGap: CGFloat = 6,
        shadowInset: CGFloat = 16,
        shadowBottomInset: CGFloat = 24,
        screenMargin: CGFloat = 16,
        cardSpacing: CGFloat = 12,
        endMenuWidth: CGFloat = 28,
        maxCardWidth: CGFloat = 220,
        minCardWidth: CGFloat = 56
    ) {
        self.topInset = topInset
        self.railZone = railZone
        self.railGap = railGap
        self.shadowInset = shadowInset
        self.shadowBottomInset = shadowBottomInset
        self.screenMargin = screenMargin
        self.cardSpacing = cardSpacing
        self.endMenuWidth = endMenuWidth
        self.maxCardWidth = maxCardWidth
        self.minCardWidth = minCardWidth
    }

    /// Distance from the panel's top edge to the card's top edge.
    public var cardTopOffset: CGFloat {
        topInset + railZone + railGap
    }

    /// Panel-local y of the rail line.
    public var railLineY: CGFloat {
        topInset + Self.railLineOffset
    }

    /// Height of the panel for a given card height.
    public func panelHeight(cardHeight: CGFloat) -> CGFloat {
        topInset + railZone + railGap + cardHeight + shadowBottomInset
    }

    /// Width of the visible rail/card/menu content for the supplied card widths.
    public func visualWidth(cardWidths: [CGFloat]) -> CGFloat {
        guard !cardWidths.isEmpty else { return 0 }
        return cardWidths.reduce(0, +)
            + cardSpacing * CGFloat(max(0, cardWidths.count - 1))
            + endMenuWidth
    }

    /// Width of the transparent panel that hosts the visible content.
    public func panelWidth(cardWidths: [CGFloat]) -> CGFloat {
        visualWidth(cardWidths: cardWidths) + shadowInset * 2
    }
}

/// Geometry helpers for the single, chromeless screenshot-shelf panel.
public enum ScreenshotShelfGeometry {
    /// Fits card widths into the usable screen while preserving each capture's relative width.
    ///
    /// Very wide cards are capped first. If the row still does not fit, every width is scaled
    /// down; extremely narrow displays may go below `minCardWidth` so the panel never overflows.
    ///
    /// - Parameters:
    ///   - naturalWidths: Widths derived from each capture's aspect ratio at the configured height.
    ///   - availableWidth: Full width of the usable screen frame.
    ///   - metrics: Shared shelf layout constants.
    /// - Returns: Widths for the visible cards, or an empty array when no usable row fits.
    public static func fittedCardWidths(
        naturalWidths: [CGFloat],
        availableWidth: CGFloat,
        metrics: ScreenshotShelfMetrics
    ) -> [CGFloat] {
        guard availableWidth.isFinite, availableWidth > 0,
              !naturalWidths.isEmpty else { return [] }

        let validWidths = naturalWidths.filter { $0.isFinite && $0 > 0 }
        guard validWidths.count == naturalWidths.count else { return [] }

        let contentLimit = availableWidth
            - metrics.screenMargin * 2
            - metrics.endMenuWidth
            - metrics.cardSpacing * CGFloat(max(0, validWidths.count - 1))
        guard contentLimit.isFinite, contentLimit >= 1 else { return [] }

        let capped = validWidths.map {
            min(max($0, metrics.minCardWidth), metrics.maxCardWidth)
        }
        let total = capped.reduce(0, +)
        guard total > 0 else { return [] }
        guard total > contentLimit else { return capped }

        let scale = contentLimit / total
        return capped.map { max(1, $0 * scale) }
    }

    /// Computes the panel frame for the requested screen anchor.
    ///
    /// The visual rail/card content sits `screenMargin` inside the usable frame. The panel is
    /// larger by `shadowInset` on each side so card shadows and the drag scale are not clipped.
    /// For the default `.top` anchor the panel's top edge is 8 pt below the usable top (16 pt
    /// screen margin minus 8 pt top inset), and the rail itself is 16 pt below it.
    ///
    /// - Parameters:
    ///   - visibleFrame: Usable screen frame already excluding the menu bar, Dock, and notch.
    ///   - cardWidths: Fitted widths returned by `fittedCardWidths`.
    ///   - cardHeight: Configured card height in points.
    ///   - anchor: Requested screen anchor.
    ///   - metrics: Shared shelf layout constants.
    /// - Returns: Panel frame bounded by `visibleFrame`; `.zero` for invalid geometry.
    public static func panelFrame(
        visibleFrame: CGRect,
        cardWidths: [CGFloat],
        cardHeight: CGFloat,
        anchor: ScreenshotShelfAnchor,
        metrics: ScreenshotShelfMetrics = ScreenshotShelfMetrics()
    ) -> CGRect {
        guard visibleFrame.minX.isFinite,
              visibleFrame.minY.isFinite,
              visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0,
              cardHeight.isFinite,
              cardHeight > 0,
              !cardWidths.isEmpty else { return .zero }

        // A frame that cannot even hold the action menu and shadow inset is not a usable shelf.
        let minimumWidth = metrics.shadowInset * 2 + metrics.endMenuWidth
        let minimumHeight = metrics.topInset + metrics.railZone + metrics.railGap
            + metrics.shadowBottomInset + 1
        guard visibleFrame.width >= minimumWidth,
              visibleFrame.height >= minimumHeight else { return .zero }

        let panelWidth = metrics.panelWidth(cardWidths: cardWidths)
        let panelHeight = metrics.panelHeight(cardHeight: cardHeight)
        let width = min(panelWidth, visibleFrame.width)
        let height = min(panelHeight, visibleFrame.height)
        guard width > 0, height > 0 else { return .zero }

        let proposedX: CGFloat
        switch anchor.horizontalPlacement {
        case .leading:
            proposedX = visibleFrame.minX + metrics.screenMargin - metrics.shadowInset
        case .center:
            proposedX = visibleFrame.midX - width / 2
        case .trailing:
            proposedX = visibleFrame.maxX - metrics.screenMargin + metrics.shadowInset - width
        }
        let clampedX = min(max(proposedX, visibleFrame.minX), visibleFrame.maxX - width)

        let panelTop = visibleFrame.maxY - metrics.screenMargin + metrics.topInset
        let proposedY = panelTop - height
        let clampedY = min(max(proposedY, visibleFrame.minY), visibleFrame.maxY - height)

        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }

    /// Reserves room for an auto-hidden menu bar that can reappear over the shelf.
    ///
    /// `visibleFrame` normally already excludes a visible menu bar. When it is set to auto-hide,
    /// macOS can report a `visibleFrame` equal to the display frame; in that case the shelf must
    /// stay clear of the 28 pt menu-bar reveal so the cards are not covered when it slides down.
    public static func effectiveVisibleFrame(
        visibleFrame: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              screenFrame.width.isFinite,
              screenFrame.height.isFinite else { return .zero }

        var frame = visibleFrame
        if frame.maxY >= screenFrame.maxY - 1 {
            frame.size.height = max(0, frame.height - 28)
        }
        return frame
    }

    /// The compact always-visible handle that replaces the shelf while it is idle.
    ///
    /// The collapsed frame keeps the expanded frame's top edge and horizontal center, so the
    /// handle stays inside the expanded panel after it opens. That invariant matters: a handle
    /// above the expanded top edge would leave the pointer outside the panel and immediately
    /// re-collapse it.
    ///
    /// The window is kept tight to the drawn handle because macOS routes pointer events to the
    /// whole window frame, transparent pixels included. A smaller frame is the only way to reduce
    /// the pointer input the idle shelf swallows from the app underneath.
    ///
    /// - Parameters:
    ///   - expandedFrame: The expanded panel frame.
    ///   - handleWidth: Width of the handle window.
    ///   - handleHeight: Height of the handle window.
    /// - Returns: A frame with the same `maxY` and `midX`, or `.zero` for invalid input.
    public static func collapsedFrame(
        expandedFrame: CGRect,
        handleWidth: CGFloat = ScreenshotShelfMetrics.collapsedHandleWidth,
        handleHeight: CGFloat = ScreenshotShelfMetrics.collapsedHandleHeight
    ) -> CGRect {
        guard expandedFrame.minX.isFinite,
              expandedFrame.minY.isFinite,
              expandedFrame.width.isFinite,
              expandedFrame.height.isFinite,
              expandedFrame.width > 0,
              expandedFrame.height > 0,
              handleWidth.isFinite,
              handleHeight.isFinite,
              handleWidth > 0,
              handleHeight > 0 else { return .zero }

        let width = min(handleWidth, expandedFrame.width)
        let height = min(handleHeight, expandedFrame.height)
        return CGRect(
            x: expandedFrame.midX - width / 2,
            y: expandedFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Converts a point in the shelf panel's top-left-origin SwiftUI space to AppKit screen
    /// coordinates (origin bottom-left).
    ///
    /// - Parameters:
    ///   - panelFrame: The shelf panel's screen frame.
    ///   - localX: Horizontal offset from the panel's leading edge.
    ///   - localY: Vertical offset from the panel's top edge, in SwiftUI's y-down space.
    /// - Returns: The point in screen coordinates, or `.zero` for non-finite input.
    public static func shelfScreenTopLeft(
        panelFrame: CGRect,
        localX: CGFloat,
        localY: CGFloat
    ) -> CGPoint {
        guard panelFrame.minX.isFinite,
              panelFrame.maxY.isFinite,
              localX.isFinite,
              localY.isFinite else { return .zero }

        return CGPoint(
            x: panelFrame.minX + localX,
            y: panelFrame.maxY - localY
        )
    }

    /// Frame for the standalone drag-preview window.
    ///
    /// `cardTopLeft` is in AppKit screen coordinates (origin bottom-left). The preview window
    /// leaves `padding` on every side and reserves `hangerHeight` above the card so the ring,
    /// thread, lift scale, tilt, and shadow cannot be clipped by the preview window itself.
    ///
    /// - Parameters:
    ///   - cardTopLeft: Screen position of the dragged card's top-left corner.
    ///   - cardWidth: Width of the card.
    ///   - cardHeight: Height of the card.
    ///   - padding: Transparent margin around the card.
    ///   - hangerHeight: Extra room above the card for the ring and thread.
    /// - Returns: A frame in screen coordinates, or `.zero` for invalid input.
    public static func dragPreviewFrame(
        cardTopLeft: CGPoint,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        padding: CGFloat,
        hangerHeight: CGFloat
    ) -> CGRect {
        guard cardTopLeft.x.isFinite,
              cardTopLeft.y.isFinite,
              cardWidth.isFinite,
              cardHeight.isFinite,
              padding.isFinite,
              hangerHeight.isFinite,
              cardWidth > 0,
              cardHeight > 0,
              padding >= 0,
              hangerHeight >= 0 else { return .zero }

        return CGRect(
            x: cardTopLeft.x - padding,
            y: cardTopLeft.y - padding - cardHeight,
            width: cardWidth + padding * 2,
            height: cardHeight + hangerHeight + padding * 2
        )
    }
}
