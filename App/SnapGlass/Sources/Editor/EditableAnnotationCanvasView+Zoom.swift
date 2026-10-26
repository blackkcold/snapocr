import AppKit
import Foundation

// MARK: - EditableAnnotationCanvasNSView Zoom & Pan

extension EditableAnnotationCanvasNSView {
    /// Display rect for the image at the current zoom and pan.
    ///
    /// `aspectFitRect` stays the reference for "whole image visible"; zoom scales
    /// it about its centre and the pan offset shifts it. Every hit test and
    /// overlay derives from `imageDisplayRect`, so they follow automatically.
    func imageRect(for imageSize: CGSize) -> CGRect {
        let fit = aspectFitRect(imageSize: imageSize, in: bounds)
        fitImageRect = fit
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

    /// Keeps the zoomed image from being panned off screen. Axes where the image
    /// still fits stay centred.
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

    /// Shows the whole image again.
    func resetZoom() {
        zoomScale = 1
        panOffset = .zero
        notifyZoomChanged()
        refreshTextEntryLayout()
        needsDisplay = true
    }

    /// Scales the image so one image pixel covers one point.
    func actualSizeZoom() {
        guard fitImageRect.width > 0, lastImageSize.width > 0 else { return }
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
    ///   - newScale: Requested zoom relative to fit; clamped to 1…8.
    ///   - point: View point to hold still, or `nil` for the view centre.
    func applyZoom(_ newScale: CGFloat, around point: CGPoint?) {
        let clamped = min(max(newScale, 1), 8)
        guard abs(clamped - zoomScale) > 0.0001 else { return }

        if zoomScale <= 1.0001, panOffset == .zero, lastImageSize != .zero {
            imageDisplayRect = imageRect(for: lastImageSize)
        }
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
        panOffset = clampedPan(proposed, for: fitImageRect, zoom: clamped)
        notifyZoomChanged()
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
        // Panning is only meaningful once the image is larger than the view.
        panOffset = clampedPan(
            CGSize(
                width: panOffset.width + event.scrollingDeltaX,
                height: panOffset.height + event.scrollingDeltaY
            ),
            for: fitImageRect,
            zoom: zoomScale
        )
        refreshTextEntryLayout()
        needsDisplay = true
    }
}
