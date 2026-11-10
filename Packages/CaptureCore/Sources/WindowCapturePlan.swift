import CoreGraphics

// MARK: - WindowCaptureDisplay

/// A platform-neutral description of one display used by window capture planning.
///
/// `frame` is in Quartz global points (origin top-left of the main display), while
/// `pixelSize` is the display's native pixel size. `pixelScale` is therefore the
/// only value that may be used to convert window point sizes into capture pixels.
public struct WindowCaptureDisplay: Equatable, Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect
    public let pixelSize: CGSize

    public init(displayID: CGDirectDisplayID, frame: CGRect, pixelSize: CGSize) {
        self.displayID = displayID
        self.frame = frame
        self.pixelSize = pixelSize
    }

    /// Native pixels per point for this display.
    public var pixelScale: CGFloat {
        guard frame.width > 0, frame.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        return max(pixelSize.width / frame.width, pixelSize.height / frame.height)
    }
}

// MARK: - WindowCaptureSegment

/// One display-local slice of a window that spans displays on macOS 13.
public struct WindowCaptureSegment: Equatable, Sendable {
    /// The display this slice belongs to.
    public let displayID: CGDirectDisplayID
    /// The display frame in Quartz global points.
    public let displayFrame: CGRect
    /// The visible part of the window on this display, in global points.
    public let visibleRect: CGRect
    /// The same rect in display-local points, ready for `SCStreamConfiguration.sourceRect`.
    public let sourceRect: CGRect
    /// Native pixels per point for this slice (or 1 when high resolution is off).
    public let pixelScale: CGFloat
    /// The size ScreenCaptureKit should produce for this slice, at its native scale.
    public let capturePixelSize: CGSize
    /// The slice size in the composite canvas, already scaled to the common scale.
    public let outputPixelSize: CGSize
    /// The slice origin inside the composite canvas, in pixels (top-left origin).
    public let outputOrigin: CGPoint

    public init(
        displayID: CGDirectDisplayID,
        displayFrame: CGRect,
        visibleRect: CGRect,
        sourceRect: CGRect,
        pixelScale: CGFloat,
        capturePixelSize: CGSize,
        outputPixelSize: CGSize,
        outputOrigin: CGPoint
    ) {
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.visibleRect = visibleRect
        self.sourceRect = sourceRect
        self.pixelScale = pixelScale
        self.capturePixelSize = capturePixelSize
        self.outputPixelSize = outputPixelSize
        self.outputOrigin = outputOrigin
    }
}

private struct DisplayIntersection {
    let display: WindowCaptureDisplay
    let rect: CGRect
    let area: CGFloat
}

// MARK: - WindowCaptureStrategy

/// The ScreenCaptureKit strategy a window capture should use.
public enum WindowCaptureStrategy: Equatable, Sendable {
    /// macOS 14+: capture the window independently of any display.
    case desktopIndependentWindow
    /// macOS 13: one display contains the visible window; capture with `sourceRect`.
    case singleDisplaySourceRect
    /// macOS 13: the window spans displays; capture each slice and composite.
    case displaySegments
}

// MARK: - WindowCapturePlan

/// Pure geometry for window capture.
///
/// The plan encodes the invariant that the ScreenCaptureKit filter decides the
/// output canvas: a display-bound filter must never be used with a window-sized
/// buffer. `WindowCapturePlan.make` is deliberately free of ScreenCaptureKit
/// types so it can be unit tested without constructing `SCWindow`/`SCDisplay`.
public struct WindowCapturePlan: Equatable, Sendable {
    public let strategy: WindowCaptureStrategy
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    /// The content rect in global points. For a 13 slice this is the visible union.
    public let contentRect: CGRect
    /// The expected output size in pixels.
    public let outputPixelSize: CGSize
    /// The pixel-per-point scale used for the output.
    public let pointPixelScale: CGFloat
    /// The display that owns the largest visible slice, used for metadata.
    public let displayID: CGDirectDisplayID?
    public let displayFrame: CGRect?
    /// macOS 13 slices. Empty for the desktop-independent window strategy.
    public let segments: [WindowCaptureSegment]
    /// Whether the window intersects more than one display.
    public let isCrossDisplay: Bool

    public init(
        strategy: WindowCaptureStrategy,
        windowID: CGWindowID,
        windowFrame: CGRect,
        contentRect: CGRect,
        outputPixelSize: CGSize,
        pointPixelScale: CGFloat,
        displayID: CGDirectDisplayID?,
        displayFrame: CGRect?,
        segments: [WindowCaptureSegment],
        isCrossDisplay: Bool
    ) {
        self.strategy = strategy
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.contentRect = contentRect
        self.outputPixelSize = outputPixelSize
        self.pointPixelScale = pointPixelScale
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.segments = segments
        self.isCrossDisplay = isCrossDisplay
    }

    // swiftlint:disable function_body_length
    /// Builds a capture plan from window/display geometry.
    ///
    /// - Parameters:
    ///   - windowID: The target window identifier.
    ///   - windowFrame: The window frame in Quartz global points.
    ///   - displays: All available displays.
    ///   - usesDesktopIndependentWindow: Pass `true` on macOS 14+, where
    ///     `SCContentFilter(desktopIndependentWindow:)` captures the whole window.
    ///   - highResolution: When `false`, output is forced to 1x.
    /// - Returns: A plan, or `nil` when a macOS 13 window has no visible slice.
    public static func make(
        windowID: CGWindowID,
        windowFrame: CGRect,
        displays: [WindowCaptureDisplay],
        usesDesktopIndependentWindow: Bool,
        highResolution: Bool = true
    ) -> WindowCapturePlan? {
        let frame = windowFrame.standardized
        let displays = deduplicatedDisplays(displays)
        guard frame.width > 0, frame.height > 0, !displays.isEmpty else { return nil }

        let intersections = displays.compactMap { display -> DisplayIntersection? in
            let rect = frame.intersection(display.frame)
            guard !rect.isEmpty else { return nil }
            return DisplayIntersection(
                display: display,
                rect: rect,
                area: rect.width * rect.height
            )
        }.sorted { $0.area > $1.area }

        if usesDesktopIndependentWindow {
            // macOS 14+ can capture a window even when it is fully off-screen or
            // on another Space. Keep a display for metadata by choosing the
            // largest intersection, then the nearest display by center distance.
            let target = intersections.first?.display ?? closestDisplay(to: frame, in: displays)
            guard let target else { return nil }
            let scale = highResolution ? max(target.pixelScale, 1) : 1
            return WindowCapturePlan(
                strategy: .desktopIndependentWindow,
                windowID: windowID,
                windowFrame: frame,
                contentRect: frame,
                outputPixelSize: pixelSize(for: frame.size, scale: scale),
                pointPixelScale: scale,
                displayID: target.displayID,
                displayFrame: target.frame,
                segments: [],
                isCrossDisplay: intersections.count > 1
            )
        }

        guard let largest = intersections.first else { return nil }
        let commonScale = highResolution
            ? max(intersections.map { max($0.display.pixelScale, 1) }.max() ?? 1, 1)
            : 1
        let union = intersections.reduce(CGRect.null) { $0.union($1.rect) }
        guard !union.isEmpty else { return nil }

        let segments = intersections.map { intersection in
            let display = intersection.display
            let rect = intersection.rect
            let sliceScale = highResolution ? max(display.pixelScale, 1) : 1
            let origin = CGPoint(
                x: rounded((rect.minX - union.minX) * commonScale),
                y: rounded((rect.minY - union.minY) * commonScale)
            )
            return WindowCaptureSegment(
                displayID: display.displayID,
                displayFrame: display.frame,
                visibleRect: rect,
                sourceRect: CGRect(
                    x: rect.minX - display.frame.minX,
                    y: rect.minY - display.frame.minY,
                    width: rect.width,
                    height: rect.height
                ),
                pixelScale: sliceScale,
                capturePixelSize: pixelSize(for: rect.size, scale: sliceScale),
                outputPixelSize: pixelSize(for: rect.size, scale: commonScale),
                outputOrigin: origin
            )
        }

        return WindowCapturePlan(
            strategy: intersections.count == 1 ? .singleDisplaySourceRect : .displaySegments,
            windowID: windowID,
            windowFrame: frame,
            contentRect: union,
            outputPixelSize: pixelSize(for: union.size, scale: commonScale),
            pointPixelScale: commonScale,
            displayID: largest.display.displayID,
            displayFrame: largest.display.frame,
            segments: segments,
            isCrossDisplay: intersections.count > 1
        )
    }

    // swiftlint:enable function_body_length

    /// Scales every segment and the canvas into a thumbnail-sized plan.
    ///
    /// The display-local `sourceRect` stays in points; only capture/output
    /// sizes and origins shrink, so ScreenCaptureKit still reads the same
    /// window region and no content is cropped.
    public func scaledForThumbnail(maxPixelSize: CGSize) -> WindowCapturePlan {
        guard maxPixelSize.width > 0, maxPixelSize.height > 0,
              outputPixelSize.width > 0, outputPixelSize.height > 0 else {
            return self
        }
        let factor = min(
            1,
            maxPixelSize.width / outputPixelSize.width,
            maxPixelSize.height / outputPixelSize.height
        )
        guard factor < 1 else { return self }

        let scaledSegments = segments.map { segment in
            WindowCaptureSegment(
                displayID: segment.displayID,
                displayFrame: segment.displayFrame,
                visibleRect: segment.visibleRect,
                sourceRect: segment.sourceRect,
                pixelScale: segment.pixelScale,
                capturePixelSize: CGSize(
                    width: max(1, (segment.capturePixelSize.width * factor).rounded()),
                    height: max(1, (segment.capturePixelSize.height * factor).rounded())
                ),
                outputPixelSize: CGSize(
                    width: max(1, (segment.outputPixelSize.width * factor).rounded()),
                    height: max(1, (segment.outputPixelSize.height * factor).rounded())
                ),
                outputOrigin: CGPoint(
                    x: (segment.outputOrigin.x * factor).rounded(),
                    y: (segment.outputOrigin.y * factor).rounded()
                )
            )
        }
        return WindowCapturePlan(
            strategy: strategy,
            windowID: windowID,
            windowFrame: windowFrame,
            contentRect: contentRect,
            outputPixelSize: CGSize(
                width: max(1, (outputPixelSize.width * factor).rounded()),
                height: max(1, (outputPixelSize.height * factor).rounded())
            ),
            pointPixelScale: pointPixelScale * factor,
            displayID: displayID,
            displayFrame: displayFrame,
            segments: scaledSegments,
            isCrossDisplay: isCrossDisplay
        )
    }

    /// The expected output size for a window using the desktop-independent path.
    public static func desktopIndependentOutputSize(
        contentRect: CGRect,
        pointPixelScale: CGFloat
    ) -> CGSize {
        pixelSize(for: contentRect.size, scale: max(pointPixelScale, 1))
    }

    /// Mirrored displays can appear twice with the same frame. Keep the first
    /// (the system's primary entry) so window stitching never draws a duplicate.
    private static func deduplicatedDisplays(
        _ displays: [WindowCaptureDisplay]
    ) -> [WindowCaptureDisplay] {
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
            width: max(1, rounded(size.width * scale)),
            height: max(1, rounded(size.height * scale))
        )
    }

    private static func rounded(_ value: CGFloat) -> CGFloat {
        value.rounded()
    }

    private static func closestDisplay(
        to frame: CGRect,
        in displays: [WindowCaptureDisplay]
    ) -> WindowCaptureDisplay? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { lhs, rhs in
            distanceSquared(from: center, to: lhs.frame) < distanceSquared(from: center, to: rhs.frame)
        }
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let deltaX = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let deltaY = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return deltaX * deltaX + deltaY * deltaY
    }
}
