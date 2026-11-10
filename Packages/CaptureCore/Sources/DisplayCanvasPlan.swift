import CoreGraphics

// MARK: - DisplayCanvasDisplay

/// A platform-neutral display description used by all-display canvas planning.
public struct DisplayCanvasDisplay: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect
    public let pixelSize: CGSize

    public init(displayID: CGDirectDisplayID, frame: CGRect, pixelSize: CGSize) {
        self.displayID = displayID
        self.frame = frame
        self.pixelSize = pixelSize
    }

    public var pixelScale: CGFloat {
        guard frame.width > 0, frame.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        return max(pixelSize.width / frame.width, pixelSize.height / frame.height)
    }
}

// MARK: - DisplayCanvasMode

/// How displays are arranged on the output canvas.
public enum DisplayCanvasMode: String, CaseIterable, Sendable {
    /// Edge-to-edge horizontal strip, ordered by the system's left-to-right layout.
    case compactHorizontal
    /// Edge-to-edge vertical strip, ordered by the system's top-to-bottom layout.
    case compactVertical
    /// Preserve the system's relative positions, including L-shaped canvases.
    case physical
}

/// Alignment used by compact strips.
public enum DisplayCanvasAlignment: String, CaseIterable, Sendable {
    case start
    case center
    case end
}

// MARK: - DisplayCanvasPlacement

/// One display's placement on the composed canvas.
public struct DisplayCanvasPlacement: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let sourceFrame: CGRect
    public let canvasOrigin: CGPoint
    public let outputPixelSize: CGSize
    public let pixelScale: CGFloat

    public init(
        displayID: CGDirectDisplayID,
        sourceFrame: CGRect,
        canvasOrigin: CGPoint,
        outputPixelSize: CGSize,
        pixelScale: CGFloat
    ) {
        self.displayID = displayID
        self.sourceFrame = sourceFrame
        self.canvasOrigin = canvasOrigin
        self.outputPixelSize = outputPixelSize
        self.pixelScale = pixelScale
    }
}

// MARK: - DisplayCanvasPlan

/// Pure geometry for "all displays" captures.
///
/// Compact modes remove inserted spacing by default (`gap == 0`) and align
/// display edges directly. Physical mode preserves each display's relative
/// position; empty areas are part of the canvas silhouette.
public struct DisplayCanvasPlan: Equatable, Sendable {
    public let mode: DisplayCanvasMode
    public let gap: CGFloat
    public let alignment: DisplayCanvasAlignment
    public let canvasSize: CGSize
    public let outputPixelSize: CGSize
    public let commonScale: CGFloat
    public let placements: [DisplayCanvasPlacement]
    public let isIrregular: Bool

    public init(
        mode: DisplayCanvasMode,
        gap: CGFloat,
        alignment: DisplayCanvasAlignment,
        canvasSize: CGSize,
        outputPixelSize: CGSize,
        commonScale: CGFloat,
        placements: [DisplayCanvasPlacement],
        isIrregular: Bool
    ) {
        self.mode = mode
        self.gap = gap
        self.alignment = alignment
        self.canvasSize = canvasSize
        self.outputPixelSize = outputPixelSize
        self.commonScale = commonScale
        self.placements = placements
        self.isIrregular = isIrregular
    }

    public static func make(
        displays: [DisplayCanvasDisplay],
        mode: DisplayCanvasMode,
        gap: CGFloat = 0,
        alignment: DisplayCanvasAlignment = .start,
        highResolution: Bool = true
    ) -> DisplayCanvasPlan? {
        let usable = deduplicated(displays.filter {
            $0.frame.width > 0 && $0.frame.height > 0
                && $0.pixelSize.width > 0 && $0.pixelSize.height > 0
        })
        guard !usable.isEmpty else { return nil }

        let commonScale = highResolution
            ? max(usable.map { max($0.pixelScale, 1) }.max() ?? 1, 1)
            : 1
        let resolvedGap = max(0, gap)

        switch mode {
        case .compactHorizontal:
            return makeCompact(
                displays: usable,
                axis: .horizontal,
                gap: resolvedGap,
                alignment: alignment,
                commonScale: commonScale
            )
        case .compactVertical:
            return makeCompact(
                displays: usable,
                axis: .vertical,
                gap: resolvedGap,
                alignment: alignment,
                commonScale: commonScale
            )
        case .physical:
            return makePhysical(displays: usable, commonScale: commonScale)
        }
    }

    private enum Axis {
        case horizontal
        case vertical
    }

    private static func makeCompact(
        displays: [DisplayCanvasDisplay],
        axis: Axis,
        gap: CGFloat,
        alignment: DisplayCanvasAlignment,
        commonScale: CGFloat
    ) -> DisplayCanvasPlan {
        let ordered = displays.sorted { lhs, rhs in
            switch axis {
            case .horizontal:
                if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
                return lhs.frame.minY < rhs.frame.minY
            case .vertical:
                if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
                return lhs.frame.minX < rhs.frame.minX
            }
        }

        let canvasSize: CGSize
        switch axis {
        case .horizontal:
            canvasSize = CGSize(
                width: ordered.reduce(0) { $0 + $1.frame.width }
                    + gap * CGFloat(max(ordered.count - 1, 0)),
                height: ordered.map(\.frame.height).max() ?? 0
            )
        case .vertical:
            canvasSize = CGSize(
                width: ordered.map(\.frame.width).max() ?? 0,
                height: ordered.reduce(0) { $0 + $1.frame.height }
                    + gap * CGFloat(max(ordered.count - 1, 0))
            )
        }

        var cursor: CGFloat = 0
        let placements = ordered.map { display -> DisplayCanvasPlacement in
            let origin: CGPoint
            switch axis {
            case .horizontal:
                origin = CGPoint(
                    x: cursor,
                    y: alignedCoordinate(
                        available: canvasSize.height - display.frame.height,
                        alignment: alignment
                    )
                )
                cursor += display.frame.width + gap
            case .vertical:
                origin = CGPoint(
                    x: alignedCoordinate(
                        available: canvasSize.width - display.frame.width,
                        alignment: alignment
                    ),
                    y: cursor
                )
                cursor += display.frame.height + gap
            }
            return DisplayCanvasPlacement(
                displayID: display.displayID,
                sourceFrame: display.frame,
                canvasOrigin: origin,
                outputPixelSize: pixelSize(for: display.frame.size, scale: commonScale),
                pixelScale: commonScale
            )
        }

        return DisplayCanvasPlan(
            mode: axis == .horizontal ? .compactHorizontal : .compactVertical,
            gap: gap,
            alignment: alignment,
            canvasSize: canvasSize,
            outputPixelSize: pixelSize(for: canvasSize, scale: commonScale),
            commonScale: commonScale,
            placements: placements,
            isIrregular: false
        )
    }

    private static func makePhysical(
        displays: [DisplayCanvasDisplay],
        commonScale: CGFloat
    ) -> DisplayCanvasPlan {
        let union = displays.reduce(CGRect.null) { $0.union($1.frame) }
        let placements = displays.map { display in
            DisplayCanvasPlacement(
                displayID: display.displayID,
                sourceFrame: display.frame,
                canvasOrigin: CGPoint(
                    x: display.frame.minX - union.minX,
                    y: display.frame.minY - union.minY
                ),
                outputPixelSize: pixelSize(for: display.frame.size, scale: commonScale),
                pixelScale: commonScale
            )
        }
        let unionArea = displays.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height }
        let isIrregular = union.width * union.height > unionArea + 0.5
        return DisplayCanvasPlan(
            mode: .physical,
            gap: 0,
            alignment: .start,
            canvasSize: union.size,
            outputPixelSize: pixelSize(for: union.size, scale: commonScale),
            commonScale: commonScale,
            placements: placements,
            isIrregular: isIrregular
        )
    }

    private static func alignedCoordinate(
        available: CGFloat,
        alignment: DisplayCanvasAlignment
    ) -> CGFloat {
        switch alignment {
        case .start: return 0
        case .center: return max(0, available / 2)
        case .end: return max(0, available)
        }
    }

    /// Mirrored displays can appear twice with the same frame; keep one.
    private static func deduplicated(
        _ displays: [DisplayCanvasDisplay]
    ) -> [DisplayCanvasDisplay] {
        var seen = Set<String>()
        return displays.filter { display in
            // Frame-only: mirrored displays can report different backing pixel
            // sizes while representing the same screen.
            let key = "\(display.frame.origin.x),\(display.frame.origin.y),"
                + "\(display.frame.width),\(display.frame.height)"
            return seen.insert(key).inserted
        }
    }

    private static func pixelSize(for size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }
}
