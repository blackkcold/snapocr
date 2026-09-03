import AnnotationCore
import AppKit
import CoreText
import OCRCore
import SharedKit
import SwiftUI

// MARK: - OCR 文本选取、布局与绘制

extension EditableAnnotationCanvasNSView {
    func drawOCROverlay(in context: CGContext) {
        context.saveGState()
        for line in ocrLines {
            let rect = viewRect(from: line.editorBoundingBox)
            context.setFillColor(NSColor.systemBlue.withAlphaComponent(currentTool == .ocr ? 0.06 : 0.035).cgColor)
            context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(currentTool == .ocr ? 0.55 : 0.25).cgColor)
            context.setLineWidth(currentTool == .ocr ? 1 : 0.75)
            context.fill(rect)
            context.stroke(rect)
        }

        if currentTool == .ocr || currentTool == .select, let selection = ocrTextSelection {
            if selection.isEmpty {
                drawOCRInsertionPoint(selection.extent, in: context)
            } else {
                context.setFillColor(
                    NSColor.selectedContentBackgroundColor.withAlphaComponent(0.68).cgColor
                )
                for rect in ocrSelectionRects(for: selection) {
                    context.fill(rect)
                }
                // 保留截图中的原始文字像素。重新绘制近似系统字体会因字形、基线和
                // 水平缩放不同而让选中文字产生视觉位移。
            }
        }
        context.restoreGState()
    }

    func drawOCRInsertionPoint(_ position: OCRTextPosition, in context: CGContext) {
        guard orderedOCRLines.indices.contains(position.lineIndex) else { return }
        let line = orderedOCRLines[position.lineIndex]
        let layout = ocrLineLayout(for: line)
        let offset = min(position.offset, (line.text as NSString).length)
        let insertionX = layout.rect.minX
            + CTLineGetOffsetForStringIndex(layout.line, offset, nil) * layout.horizontalScale
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: insertionX, y: layout.rect.minY + 1))
        context.addLine(to: CGPoint(x: insertionX, y: layout.rect.maxY - 1))
        context.strokePath()
    }

    func ocrSelectionRects(for selection: OCRTextSelection) -> [CGRect] {
        let lines = orderedOCRLines
        return selection.slices(in: lines.map(\.text)).compactMap { slice in
            guard slice.length > 0, lines.indices.contains(slice.lineIndex) else { return nil }
            let layout = ocrLineLayout(for: lines[slice.lineIndex])
            let start = CTLineGetOffsetForStringIndex(layout.line, slice.location, nil)
            let end = CTLineGetOffsetForStringIndex(layout.line, NSMaxRange(slice.range), nil)
            let minX = layout.rect.minX + min(start, end) * layout.horizontalScale
            let maxX = layout.rect.minX + max(start, end) * layout.horizontalScale
            return CGRect(
                x: minX,
                y: layout.rect.minY,
                width: max(maxX - minX, 1.5),
                height: layout.rect.height
            )
        }
    }

    struct OCRLineHit {
        let index: Int
        let line: OCRLine
        let rect: CGRect
    }

    struct OCRLineLayout {
        let line: CTLine
        let rect: CGRect
        let horizontalScale: CGFloat
    }

    var orderedOCRLines: [OCRLine] {
        ocrLines
            .filter { !$0.text.isEmpty && !$0.editorBoundingBox.isEmpty }
            .sorted { lhs, rhs in
                let lhsRect = lhs.editorBoundingBox
                let rhsRect = rhs.editorBoundingBox
                let rowTolerance = max(lhsRect.height, rhsRect.height) * 0.5
                if abs(lhsRect.midY - rhsRect.midY) > rowTolerance {
                    return lhsRect.midY > rhsRect.midY
                }
                return lhsRect.minX < rhsRect.minX
            }
    }

    func ocrLineHit(at point: CGPoint) -> OCRLineHit? {
        orderedOCRLines.enumerated().compactMap { index, line -> OCRLineHit? in
            let rect = viewRect(from: line.editorBoundingBox).insetBy(dx: -3, dy: -3)
            return rect.contains(point) ? OCRLineHit(index: index, line: line, rect: rect) : nil
        }.min { lhs, rhs in
            abs(lhs.rect.midY - point.y) < abs(rhs.rect.midY - point.y)
        }
    }

    func closestOCRLineHit(to point: CGPoint) -> OCRLineHit? {
        let hits = orderedOCRLines.enumerated().map { index, line in
            OCRLineHit(index: index, line: line, rect: viewRect(from: line.editorBoundingBox))
        }
        return hits.min { lhs, rhs in
            distance(from: point, to: lhs.rect) < distance(from: point, to: rhs.rect)
        }
    }

    func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let deltaX = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let deltaY = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(deltaX, deltaY)
    }

    func textPosition(in hit: OCRLineHit, at point: CGPoint) -> OCRTextPosition {
        let layout = ocrLineLayout(for: hit.line)
        let textLength = (hit.line.text as NSString).length
        let localX = (point.x - layout.rect.minX) / max(layout.horizontalScale, 0.001)
        let index = CTLineGetStringIndexForPosition(
            layout.line,
            CGPoint(x: localX, y: 0)
        )
        let offset: Int
        if index == kCFNotFound {
            offset = point.x <= layout.rect.midX ? 0 : textLength
        } else {
            offset = min(max(index, 0), textLength)
        }
        return OCRTextPosition(lineIndex: hit.index, offset: offset)
    }

    func ocrLineLayout(for line: OCRLine) -> OCRLineLayout {
        let rect = viewRect(from: line.editorBoundingBox)
        let font = fittedOCRFont(for: line.text, in: rect.size)
        let attributedString = NSAttributedString(
            string: line.text,
            attributes: [.font: font]
        )
        let textLine = CTLineCreateWithAttributedString(attributedString)
        let measuredWidth = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
        return OCRLineLayout(
            line: textLine,
            rect: rect,
            horizontalScale: rect.width / max(measuredWidth, 1)
        )
    }

    func updateOCRTextOverlay() {
        if let image, bounds.width > 0, bounds.height > 0 {
            imageDisplayRect = aspectFitRect(
                imageSize: CGSize(width: image.width, height: image.height),
                in: bounds
            )
        }
        let newContentSignature = ocrLines.map {
            "\($0.text)|\($0.editorBoundingBox.origin.x)|\($0.editorBoundingBox.origin.y)"
                + "|\($0.editorBoundingBox.width)|\($0.editorBoundingBox.height)"
        }.joined(separator: "\n")
        if newContentSignature != ocrContentSignature {
            ocrContentSignature = newContentSignature
            ocrTextSelection = nil
            if case .selectingOCRText = interaction {
                interaction = .none
            }
        }
        if let selection = ocrTextSelection {
            let lines = orderedOCRLines
            let endpoints = selection.orderedEndpoints
            if lines.isEmpty || endpoints.end.lineIndex >= lines.count {
                ocrTextSelection = nil
            }
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func fittedOCRFont(for text: String, in size: CGSize) -> NSFont {
        let heightLimitedSize = max(8, size.height * 0.78)
        let baseFont = NSFont.systemFont(ofSize: heightLimitedSize)
        let measuredWidth = (text as NSString).size(withAttributes: [.font: baseFont]).width
        guard measuredWidth > size.width, measuredWidth > 0 else { return baseFont }
        return NSFont.systemFont(ofSize: max(6, heightLimitedSize * size.width / measuredWidth))
    }
}
