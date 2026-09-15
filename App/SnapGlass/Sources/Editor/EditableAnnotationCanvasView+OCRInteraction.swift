import AnnotationCore
import AppKit
import OCRCore
import SharedKit
import SwiftUI

// MARK: - EditableAnnotationCanvasNSView OCR Interaction

extension EditableAnnotationCanvasNSView {
    func handleOCRKeyDown(_ event: NSEvent) -> Bool {
        let character = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command) {
            if character == "c" {
                return copySelectedOCRText()
            }
            if currentTool == .ocr, character == "a", let lastLine = orderedOCRLines.indices.last {
                ocrTextSelection = OCRTextSelection(
                    anchor: OCRTextPosition(lineIndex: 0, offset: 0),
                    extent: OCRTextPosition(
                        lineIndex: lastLine,
                        offset: (orderedOCRLines[lastLine].text as NSString).length
                    )
                )
                needsDisplay = true
                return true
            }
        }

        if currentTool == .ocr, event.keyCode == 53 {
            ocrTextSelection = nil
            needsDisplay = true
            return true
        }

        guard currentTool == .ocr,
              [UInt16(123), 124, 125, 126].contains(event.keyCode),
              !orderedOCRLines.isEmpty else { return false }
        moveOCRCaret(
            keyCode: event.keyCode,
            extendsSelection: event.modifierFlags.contains(.shift)
        )
        return true
    }

    private func moveOCRCaret(keyCode: UInt16, extendsSelection: Bool) {
        let lines = orderedOCRLines.map(\.text)
        let fallback = OCRTextPosition(lineIndex: 0, offset: 0)
        let selection = ocrTextSelection ?? OCRTextSelection(anchor: fallback, extent: fallback)

        if !extendsSelection, !selection.isEmpty {
            let endpoints = selection.orderedEndpoints
            let collapsed = keyCode == 123 || keyCode == 126
                ? endpoints.start
                : endpoints.end
            ocrTextSelection = OCRTextSelection(anchor: collapsed, extent: collapsed)
            needsDisplay = true
            return
        }

        let moved = movedOCRPosition(selection.extent, keyCode: keyCode, lines: lines)
        let anchor = extendsSelection ? selection.anchor : moved
        ocrTextSelection = OCRTextSelection(anchor: anchor, extent: moved)
        needsDisplay = true
    }

    private func movedOCRPosition(
        _ position: OCRTextPosition,
        keyCode: UInt16,
        lines: [String]
    ) -> OCRTextPosition {
        let lineIndex = min(position.lineIndex, lines.count - 1)
        let text = lines[lineIndex] as NSString
        let offset = min(position.offset, text.length)

        switch keyCode {
        case 123:
            if offset > 0 {
                let range = text.rangeOfComposedCharacterSequence(at: offset - 1)
                return OCRTextPosition(lineIndex: lineIndex, offset: range.location)
            }
            guard lineIndex > 0 else { return OCRTextPosition(lineIndex: 0, offset: 0) }
            return OCRTextPosition(
                lineIndex: lineIndex - 1,
                offset: (lines[lineIndex - 1] as NSString).length
            )
        case 124:
            if offset < text.length {
                let range = text.rangeOfComposedCharacterSequence(at: offset)
                return OCRTextPosition(lineIndex: lineIndex, offset: NSMaxRange(range))
            }
            guard lineIndex + 1 < lines.count else { return OCRTextPosition(lineIndex: lineIndex, offset: offset) }
            return OCRTextPosition(lineIndex: lineIndex + 1, offset: 0)
        case 125:
            guard lineIndex + 1 < lines.count else { return OCRTextPosition(lineIndex: lineIndex, offset: offset) }
            return OCRTextPosition(
                lineIndex: lineIndex + 1,
                offset: min(offset, (lines[lineIndex + 1] as NSString).length)
            )
        default:
            guard lineIndex > 0 else { return OCRTextPosition(lineIndex: 0, offset: min(offset, text.length)) }
            return OCRTextPosition(
                lineIndex: lineIndex - 1,
                offset: min(offset, (lines[lineIndex - 1] as NSString).length)
            )
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard currentTool == .ocr || currentTool == .select else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = ocrLineHit(at: point) else { return nil }
        let line = hit.line
        contextualOCRLine = line
        let position = textPosition(in: hit, at: point)
        if ocrTextSelection?.contains(position) != true {
            ocrTextSelection = .wordSelection(
                in: line.text,
                lineIndex: hit.index,
                offset: position.offset
            )
            needsDisplay = true
        }

        let menu = NSMenu()
        let copySelection = menu.addItem(
            withTitle: AppLocalization.string("Copy"),
            action: #selector(copyContextualOCRSelection),
            keyEquivalent: ""
        )
        copySelection.isEnabled = ocrTextSelection?.isEmpty == false
        menu.addItem(
            withTitle: AppLocalization.string("Copy Line"),
            action: #selector(copyContextualOCRLine),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: AppLocalization.string("Add as Text Annotation"),
            action: #selector(addContextualOCRLine),
            keyEquivalent: ""
        )
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func copyContextualOCRSelection() {
        _ = copySelectedOCRText()
    }

    @objc private func copyContextualOCRLine() {
        guard let contextualOCRLine else { return }
        onOCRLinesCopied?([contextualOCRLine])
    }

    @objc private func addContextualOCRLine() {
        guard let contextualOCRLine else { return }
        onOCRLineAsAnnotation?(contextualOCRLine)
    }

    func beginOCRTextSelection(
        at point: CGPoint,
        clickCount: Int,
        extendsSelection: Bool
    ) {
        guard let hit = ocrLineHit(at: point) else {
            ocrTextSelection = nil
            interaction = .none
            needsDisplay = true
            return
        }

        let position = textPosition(in: hit, at: point)
        if clickCount >= 3 {
            ocrTextSelection = .lineSelection(in: hit.line.text, lineIndex: hit.index)
            interaction = .none
        } else if clickCount == 2 {
            ocrTextSelection = .wordSelection(
                in: hit.line.text,
                lineIndex: hit.index,
                offset: position.offset
            )
            interaction = .none
        } else {
            let anchor = extendsSelection ? (ocrTextSelection?.anchor ?? position) : position
            ocrTextSelection = OCRTextSelection(anchor: anchor, extent: position)
            interaction = .selectingOCRText
        }
        needsDisplay = true
    }

    func updateOCRTextSelection(to point: CGPoint) {
        guard let anchor = ocrTextSelection?.anchor,
              let hit = closestOCRLineHit(to: point) else { return }
        ocrTextSelection = OCRTextSelection(
            anchor: anchor,
            extent: textPosition(in: hit, at: point)
        )
    }

    @discardableResult
    private func copySelectedOCRText() -> Bool {
        guard let selection = ocrTextSelection, !selection.isEmpty else { return false }
        let text = selection.selectedText(in: orderedOCRLines.map(\.text))
        guard !text.isEmpty else { return false }
        onOCRTextCopied?(text)
        return true
    }
}
