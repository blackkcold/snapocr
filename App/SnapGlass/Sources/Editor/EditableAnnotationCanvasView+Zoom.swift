import AppKit
import CaptureCore
import Foundation

// MARK: - EditableAnnotationCanvasNSView Zoom & Pan

extension EditableAnnotationCanvasNSView {
    /// Geometry for the current image and share style.
    ///
    /// With share appearance off this is a zero-treatment layout, so hit
    /// testing, zoom and drawing all follow one code path.
    func mockupLayout(for imageSize: CGSize) -> MockupLayout {
        if let shareStyle {
            return MockupLayout.make(imageSize: imageSize, style: shareStyle)
        }
        return MockupLayout.raw(imageSize: imageSize)
    }

    /// The whole treatment frame, fit into the view before zoom and pan.
    func fitCanvasRect(for imageSize: CGSize) -> CGRect {
        let layout = mockupLayout(for: imageSize)
        return aspectFitRect(imageSize: layout.canvasSize, in: bounds)
    }

    /// The treatment frame at the current zoom and pan.
    func canvasRect(for imageSize: CGSize) -> CGRect {
        let layout = mockupLayout(for: imageSize)
        let fit = fitCanvasRect(for: imageSize)
        fitCanvasRect = fit
        fitImageRect = layout.contentRect(
            in: fit.origin,
            scale: fit.width / max(layout.canvasSize.width, 1)
        )

        guard zoomScale != 1 || panOffset != .zero else { return fit }

        panOffset = clampedPan(panOffset, for: fit, zoom: zoomScale)
        let width = fit.width * zoomScale
        let height = fit.height * zoomScale
        return CGRect(
            x: fit.midX + panOffset.width - width / 2,
            y: fit.midY + panOffset.height - height / 2,
            width: width,
            height: height
        )
    }

    /// Display rect for the image at the current zoom and pan.
    ///
    /// This stays the single anchor for every hit test and overlay: it is the
    /// layout's content rect mapped into the view, whether or not share
    /// appearance adds padding around it.
    func imageRect(for imageSize: CGSize) -> CGRect {
        let layout = mockupLayout(for: imageSize)
        let frame = canvasRect(for: imageSize)
        return layout.contentRect(
            in: frame.origin,
            scale: frame.width / max(layout.canvasSize.width, 1)
        )
    }

    /// Adopts a share style without losing the user's place.
    ///
    /// At fit the whole card is shown, because that is what turning the
    /// treatment on should look like. While zoomed in, the image keeps its
    /// on-screen size and centre so detail work does not jump.
    func applyShareStyle(_ style: MockupStyle?, preservingPresentation: Bool = true) {
        guard style != shareStyle else { return }
        let previousContent = imageDisplayRect
        let previousSize = lastImageSize
        let isToggle = (style == nil) != (shareStyle == nil)
        shareStyle = style

        if isToggle,
           preservingPresentation,
           zoomScale > 1.0001,
           previousSize != .zero,
           previousContent.width > 0,
           previousContent.height > 0 {
            let layout = mockupLayout(for: previousSize)
            let fit = fitCanvasRect(for: previousSize)
            let fitContent = layout.contentRect(
                in: fit.origin,
                scale: fit.width / max(layout.canvasSize.width, 1)
            )
            if fitContent.width > 0 {
                zoomScale = min(
                    max(previousContent.width / fitContent.width, 1),
                    CanvasZoomController.maximumScale
                )
                panOffset = clampedPan(
                    CGSize(
                        width: previousContent.midX - fit.midX,
                        height: previousContent.midY - fit.midY
                    ),
                    for: fit,
                    zoom: zoomScale
                )
            } else {
                zoomScale = 1
                panOffset = .zero
            }
        } else if isToggle {
            zoomScale = 1
            panOffset = .zero
        }

        if previousSize != .zero {
            imageDisplayRect = imageRect(for: previousSize)
        }
        notifyZoomChanged()
        window?.invalidateCursorRects(for: self)
        refreshTextEntryLayout()
        needsDisplay = true
    }

    /// Keeps the zoomed frame from being panned off screen. Axes where the
    /// frame still fits stay centred.
    func clampedPan(_ proposed: CGSize, for fit: CGRect, zoom: CGFloat) -> CGSize {
        guard zoom > 1.0001 else { return .zero }
        let width = fit.width * zoom
        let height = fit.height * zoom
        let limitX = max(0, (width - bounds.width) / 2)
        let limitY = max(0, (height - bounds.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -limitX), limitX),
            height: min(max(proposed.height, -limitY), limitY)
        )
    }

    /// Shows the whole treated canvas again.
    func resetZoom() {
        zoomScale = 1
        panOffset = .zero
        if lastImageSize != .zero {
            imageDisplayRect = imageRect(for: lastImageSize)
        }
        notifyZoomChanged()
        window?.invalidateCursorRects(for: self)
        refreshTextEntryLayout()
        needsDisplay = true
    }

    /// Scales the image so one image pixel covers one point.
    func actualSizeZoom() {
        guard lastImageSize.width > 0 else { return }
        imageDisplayRect = imageRect(for: lastImageSize)
        guard fitImageRect.width > 0 else { return }
        applyZoom(lastImageSize.width / fitImageRect.width, around: nil)
    }

    func zoomIn() {
        applyZoom(zoomScale * 1.25, around: nil)
    }

    func zoomOut() {
        applyZoom(zoomScale / 1.25, around: nil)
    }

    /// Zooms to `newScale`, keeping the point under `point` in place.
    ///
    /// - Parameters:
    ///   - newScale: Requested zoom relative to fit; clamped to 1…`maximumScale`.
    ///   - point: View point to hold still, or `nil` for the view centre.
    func applyZoom(_ newScale: CGFloat, around point: CGPoint?) {
        let clamped = min(max(newScale, 1), CanvasZoomController.maximumScale)
        guard abs(clamped - zoomScale) > 0.0001 else { return }
        guard lastImageSize != .zero else { return }

        imageDisplayRect = imageRect(for: lastImageSize)
        let current = imageDisplayRect
        let anchor = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let relativeX = current.width > 0 ? (anchor.x - current.minX) / current.width : 0.5
        let relativeY = current.height > 0 ? (anchor.y - current.minY) / current.height : 0.5

        zoomScale = clamped
        let width = fitImageRect.width * clamped
        let height = fitImageRect.height * clamped
        let proposed = CGSize(
            width: anchor.x + (0.5 - relativeX) * width - fitImageRect.midX,
            height: anchor.y + (0.5 - relativeY) * height - fitImageRect.midY
        )
        panOffset = clampedPan(proposed, for: fitCanvasRect, zoom: clamped)
        imageDisplayRect = imageRect(for: lastImageSize)
        notifyZoomChanged()
        window?.invalidateCursorRects(for: self)
        refreshTextEntryLayout()
        needsDisplay = true
    }

    /// Keeps the inline text field aligned after a zoom or pan.
    func refreshTextEntryLayout() {
        guard canvasTextEditor != nil, lastImageSize != .zero else { return }
        imageDisplayRect = imageRect(for: lastImageSize)
        layoutTextEntry()
    }

    private func notifyZoomChanged() {
        let actualScale = fitImageRect.width > 0 && lastImageSize.width > 0
            ? (fitImageRect.width * zoomScale) / lastImageSize.width
            : 1
        onZoomChanged?(zoomScale, actualScale)
    }

    // MARK: - Gestures

    /// Handles the zoom shortcuts and the space-held pan modifier.
    ///
    /// - Returns: `true` when the event was consumed.
    func handleZoomKeyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let characters = event.charactersIgnoringModifiers {
            switch characters {
            case "0":
                resetZoom()
                return true
            case "1":
                actualSizeZoom()
                return true
            case "=", "+":
                zoomIn()
                return true
            case "-", "_":
                zoomOut()
                return true
            default:
                break
            }
        }
        if event.keyCode == 49 {
            // Space is a modal pan modifier while held, as in every design tool.
            if !event.isARepeat {
                isSpacePanning = true
                NSCursor.openHand.set()
            }
            return true
        }
        return false
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        applyZoom(zoomScale * (1 + event.magnification), around: point)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let divisor: CGFloat = event.hasPreciseScrollingDeltas ? 80 : 8
            applyZoom(zoomScale * (1 + event.scrollingDeltaY / divisor), around: point)
            return
        }
        guard zoomScale > 1.0001 else {
            super.scrollWheel(with: event)
            return
        }
        // Panning is only meaningful once the frame is larger than the view.
        let fit = fitCanvasRect(for: lastImageSize)
        panOffset = clampedPan(
            CGSize(
                width: panOffset.width + event.scrollingDeltaX,
                height: panOffset.height + event.scrollingDeltaY
            ),
            for: fit,
            zoom: zoomScale
        )
        if lastImageSize != .zero {
            imageDisplayRect = imageRect(for: lastImageSize)
        }
        refreshTextEntryLayout()
        needsDisplay = true
    }
}
