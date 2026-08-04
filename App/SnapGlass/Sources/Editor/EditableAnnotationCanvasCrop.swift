import AnnotationCore
import AppKit

extension EditableAnnotationCanvasNSView {
    func prepareVerticalCropIfNeeded() {
        guard verticalCropOnly, currentTool == .crop, image != nil,
              pendingCropRect.isEmpty else { return }
        pendingCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        interaction = .adjustingCrop
        needsDisplay = true
    }

    func beginCropInteraction(at point: CGPoint, clickCount: Int) {
        if verticalCropOnly {
            prepareVerticalCropIfNeeded()
            if clickCount == 2, viewRect(from: pendingCropRect).contains(point) {
                confirmPendingCrop()
                return
            }
            cropInteractionStartRect = pendingCropRect
            if let handle = cropResizeHandle(at: point) {
                interaction = .resizingCrop(handle)
            } else {
                interaction = .adjustingCrop
            }
            return
        }

        let cropViewRect = viewRect(from: pendingCropRect)
        if !pendingCropRect.isEmpty {
            if clickCount == 2, cropViewRect.contains(point) {
                confirmPendingCrop()
                return
            }
            if let handle = cropResizeHandle(at: point) {
                cropInteractionStartRect = pendingCropRect
                interaction = .resizingCrop(handle)
                return
            }
            if cropViewRect.contains(point) {
                cropInteractionStartRect = pendingCropRect
                interaction = .movingCrop
                return
            }
        }

        pendingCropRect = .zero
        cropInteractionStartRect = .zero
        interaction = .drawing
        dragCurrentPoints = []
        dragCurrentRect = .zero
    }

    func updateCropMove(to point: CGPoint) {
        guard !cropInteractionStartRect.isEmpty else { return }
        let start = normalizedPoint(dragStartPoint)
        let current = normalizedPoint(point)
        let delta = CGPoint(x: current.x - start.x, y: current.y - start.y)
        let safeDX = min(
            max(delta.x, -cropInteractionStartRect.minX),
            1 - cropInteractionStartRect.maxX
        )
        let safeDY = min(
            max(delta.y, -cropInteractionStartRect.minY),
            1 - cropInteractionStartRect.maxY
        )
        pendingCropRect = cropInteractionStartRect.offsetBy(dx: safeDX, dy: safeDY)
    }

    func updateCropResize(handle: ResizeHandle, to point: CGPoint) {
        guard !cropInteractionStartRect.isEmpty else { return }
        pendingCropRect = resizedCropBounds(
            cropInteractionStartRect,
            handle: handle,
            point: normalizedPoint(point)
        )
    }

    func confirmPendingCrop() {
        let cropViewRect = viewRect(from: pendingCropRect)
        guard currentTool == .crop,
              cropViewRect.width > 5,
              cropViewRect.height > 5 else { return }
        let node = makeNode(
            tool: .crop,
            points: [],
            normalizedRect: pendingCropRect,
            opacity: currentOpacity
        )
        cancelPendingCrop()
        onNodeCreated?(node)
    }

    func cancelPendingCrop() {
        pendingCropRect = .zero
        cropInteractionStartRect = .zero
        interaction = .none
        dragCurrentPoints = []
        dragCurrentRect = .zero
        needsDisplay = true
    }

    func drawPendingCrop(in context: CGContext) {
        guard currentTool == .crop, !pendingCropRect.isEmpty else { return }
        let rect = viewRect(from: pendingCropRect)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        context.addRect(imageDisplayRect)
        context.addRect(rect)
        context.drawPath(using: .eoFill)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.stroke(rect.insetBy(dx: -1, dy: -1))
        for handle in cropResizeHandles {
            let point = handlePoint(handle, in: rect)
            context.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        }
        context.restoreGState()

        drawCropConfirmationHint(for: rect)
    }

    private func drawCropConfirmationHint(for rect: CGRect) {
        let hint = verticalCropOnly
            ? NSLocalizedString(
                "Drag the top or bottom edge, then press Return",
                comment: "Long screenshot endpoint trim hint"
            )
            : NSLocalizedString(
                "Return / double-click to crop",
                comment: "Crop confirmation hint"
            )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (hint as NSString).size(withAttributes: attributes)
        let minimumCenterX = imageDisplayRect.minX + size.width / 2 + 8
        let maximumCenterX = imageDisplayRect.maxX - size.width / 2 - 8
        let centerX = min(max(rect.midX, minimumCenterX), maximumCenterX)
        let preferredY = rect.minY - size.height - 16
        let originY = preferredY >= imageDisplayRect.minY
            ? preferredY
            : min(rect.maxY + 8, imageDisplayRect.maxY - size.height - 8)
        let labelRect = CGRect(
            x: centerX - size.width / 2 - 6,
            y: originY,
            width: size.width + 12,
            height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        (hint as NSString).draw(
            at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 4),
            withAttributes: attributes
        )
    }

    private var cropResizeHandles: [ResizeHandle] {
        if verticalCropOnly {
            return [.bottom, .top]
        }
        return [
            .bottomLeft, .bottom, .bottomRight, .right,
            .topRight, .top, .topLeft, .left,
        ]
    }

    private func cropResizeHandle(at point: CGPoint) -> ResizeHandle? {
        let rect = viewRect(from: pendingCropRect)
        if verticalCropOnly {
            if abs(point.y - rect.minY) <= 8 { return .bottom }
            if abs(point.y - rect.maxY) <= 8 { return .top }
            return nil
        }
        return cropResizeHandles.first { handle in
            let center = handlePoint(handle, in: rect)
            return CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
                .contains(point)
        }
    }

    private func resizedCropBounds(
        _ bounds: CGRect,
        handle: ResizeHandle,
        point: CGPoint
    ) -> CGRect {
        let minimum = CGSize(
            width: 5 / max(imageDisplayRect.width, 1),
            height: 5 / max(imageDisplayRect.height, 1)
        )
        var minX = bounds.minX
        var maxX = bounds.maxX
        var minY = bounds.minY
        var maxY = bounds.maxY
        switch handle {
        case .bottomLeft:
            minX = min(point.x, maxX - minimum.width)
            minY = min(point.y, maxY - minimum.height)
        case .bottom:
            minY = min(point.y, maxY - minimum.height)
        case .bottomRight:
            maxX = max(point.x, minX + minimum.width)
            minY = min(point.y, maxY - minimum.height)
        case .right:
            maxX = max(point.x, minX + minimum.width)
        case .topRight:
            maxX = max(point.x, minX + minimum.width)
            maxY = max(point.y, minY + minimum.height)
        case .top:
            maxY = max(point.y, minY + minimum.height)
        case .topLeft:
            minX = min(point.x, maxX - minimum.width)
            maxY = max(point.y, minY + minimum.height)
        case .left:
            minX = min(point.x, maxX - minimum.width)
        case .start, .end:
            break
        }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
