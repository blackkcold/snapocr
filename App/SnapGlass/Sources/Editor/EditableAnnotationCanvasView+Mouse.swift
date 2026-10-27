import AnnotationCore
import AppKit
import OCRCore
import SharedKit
import SwiftUI

// MARK: - EditableAnnotationCanvasNSView Mouse Interaction

extension EditableAnnotationCanvasNSView {
    override func mouseDown(with event: NSEvent) {
        if let editor = canvasTextEditor {
            // Clicking elsewhere on the canvas finishes the draft rather than
            // discarding it. Esc remains the explicit cancel path.
            editor.onCommit?(editor.string)
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if isSpacePanning {
            interaction = .panning
            dragStartPoint = point
            NSCursor.closedHand.set()
            return
        }
        guard imageDisplayRect.contains(point) else { return }
        dragStartPoint = point

        switch currentTool {
        case .select:
            beginSelectionInteraction(at: point, clickCount: event.clickCount)
            // 未命中任何标注节点（空白点）且命中 OCR 行时，转 OCR 文本选取。
            if selectedNodeID == nil, ocrLineHit(at: point) != nil {
                beginOCRTextSelection(
                    at: point,
                    clickCount: event.clickCount,
                    extendsSelection: event.modifierFlags.contains(.shift)
                )
            }
        case .ocr:
            beginOCRTextSelection(
                at: point,
                clickCount: event.clickCount,
                extendsSelection: event.modifierFlags.contains(.shift)
            )
        case .crop:
            beginCropInteraction(at: point, clickCount: event.clickCount)
        case .picker:
            interaction = .drawing
            dragStartPoint = point
            dragCurrentRect = .zero
            pickerRegionRect = .zero
        default:
            interaction = .drawing
            dragCurrentPoints = [normalizedPoint(point)]
            dragCurrentRect = .zero
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampedViewPoint(convert(event.locationInWindow, from: nil))
        switch interaction {
        case .panning:
            // No clamping here: a pan may legitimately drag past the image edge.
            let raw = convert(event.locationInWindow, from: nil)
            panOffset = clampedPan(
                CGSize(
                    width: panOffset.width + (raw.x - dragStartPoint.x),
                    height: panOffset.height + (raw.y - dragStartPoint.y)
                ),
                for: fitImageRect,
                zoom: zoomScale
            )
            dragStartPoint = raw
            needsDisplay = true
        case .drawing:
            if currentTool == .picker {
                pickerRegionRect = CGRect(spanning: dragStartPoint, and: clampedViewPoint(point))
            } else {
                updateCreationPreview(to: point)
            }
        case .moving:
            updateMove(to: point)
        case .resizing(let handle):
            let adjustedPoint = CGPoint(
                x: point.x + resizePointerOffset.x,
                y: point.y + resizePointerOffset.y
            )
            updateResize(
                handle: handle,
                to: adjustedPoint,
                allowsFreeformTextScaling: event.modifierFlags.contains(.shift)
            )
        case .selectingOCRText:
            updateOCRTextSelection(to: point)
        case .adjustingCrop:
            break
        case .movingCrop:
            updateCropMove(to: point)
        case .resizingCrop(let handle):
            updateCropResize(handle: handle, to: point)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = clampedViewPoint(convert(event.locationInWindow, from: nil))
        var keepsPendingCrop = false
        defer {
            interaction = keepsPendingCrop ? .adjustingCrop : .none
            originalNode = nil
            interactiveNode = nil
            dragCurrentPoints = []
            dragCurrentRect = .zero
            pickerRegionRect = .zero
            cropInteractionStartRect = .zero
            resizePointerOffset = .zero
            invalidateRenderedPreview()
            needsDisplay = true
        }

        switch interaction {
        case .panning:
            NSCursor.openHand.set()
        case .drawing:
            keepsPendingCrop = completeDrawing(at: point)
        case .moving, .resizing:
            if let interactiveNode {
                onNodeUpdated?(interactiveNode)
            }
        case .selectingOCRText:
            updateOCRTextSelection(to: point)
        case .adjustingCrop:
            keepsPendingCrop = !pendingCropRect.isEmpty
        case .movingCrop, .resizingCrop:
            keepsPendingCrop = !pendingCropRect.isEmpty
        case .none:
            break
        }
    }

    /// 完成一次绘制交互，返回是否保留待确认的裁剪区域。
    private func completeDrawing(at point: CGPoint) -> Bool {
        if currentTool == .picker {
            let viewRect = CGRect(spanning: dragStartPoint, and: clampedViewPoint(point))
            if viewRect.width > 5, viewRect.height > 5 {
                onRegionColorsPicked?(sampledRegionColors(for: viewRect))
            } else {
                if let color = sampledColor(at: clampedViewPoint(point)) {
                    onColorPicked?(color)
                }
            }
            return false
        }
        if currentTool == .crop {
            updateCreationPreview(to: point)
            let viewRect = viewRect(from: dragCurrentRect)
            if viewRect.width > 5, viewRect.height > 5 {
                pendingCropRect = dragCurrentRect.standardized
                return true
            }
            pendingCropRect = .zero
            return false
        }
        if currentTool == .text {
            onTextRequested?(normalizedPoint(point))
        } else if let node = createNode(at: normalizedPoint(point)) {
            onNodeCreated?(node)
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if handleZoomKeyDown(event) { return }
        if handleToolKeyDown(event) { return }
        if handleCropKeyDown(event) { return }
        if currentTool == .ocr || ocrTextSelection != nil {
            if handleOCRKeyDown(event) {
                return
            }
        }
        switch event.keyCode {
        case 51, 117:
            onDeleteSelection?()
        case 53:
            // 有选中节点时先取消选中；没有选中时把 Esc 交还给窗口，
            // 否则 Cancel 按钮的 `.cancelAction` 永远收不到事件。
            if selectedNodeID != nil {
                onSelectionChanged?(nil)
            } else {
                super.keyDown(with: event)
            }
        case 123, 124, 125, 126:
            nudgeSelection(keyCode: event.keyCode, multiplier: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpacePanning = false
            NSCursor.arrow.set()
            return
        }
        super.keyUp(with: event)
    }

    /// Handles Enter/Esc while a crop rectangle is waiting for confirmation.
    ///
    /// - Returns: `true` when the event was consumed.
    func handleCropKeyDown(_ event: NSEvent) -> Bool {
        guard currentTool == .crop, !pendingCropRect.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76:
            confirmPendingCrop()
            return true
        case 53:
            cancelPendingCrop()
            return true
        default:
            return false
        }
    }
}
