import Foundation
import Testing
@testable import OCRCore

struct OCRTextSelectionTests {
    @Test func characterSelectionReturnsExactSubstring() {
        let lines = ["SnapGlass OCR"]
        let selection = OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: 0, offset: 4),
            extent: OCRTextPosition(lineIndex: 0, offset: 9)
        )

        #expect(selection.selectedText(in: lines) == "Glass")
    }

    @Test func reversedSelectionNormalizesItsEndpoints() {
        let lines = ["first", "second"]
        let selection = OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: 1, offset: 3),
            extent: OCRTextPosition(lineIndex: 0, offset: 2)
        )

        #expect(selection.selectedText(in: lines) == "rst\nsec")
    }

    @Test func selectionSpansMultipleLines() {
        let lines = ["alpha", "beta", "gamma"]
        let selection = OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: 0, offset: 2),
            extent: OCRTextPosition(lineIndex: 2, offset: 3)
        )

        #expect(selection.selectedText(in: lines) == "pha\nbeta\ngam")
        #expect(selection.slices(in: lines).map(\.range) == [
            NSRange(location: 2, length: 3),
            NSRange(location: 0, length: 4),
            NSRange(location: 0, length: 3),
        ])
    }

    @Test func wordSelectionUsesNaturalWordBoundaries() {
        let selection = OCRTextSelection.wordSelection(
            in: "Select recognized words",
            lineIndex: 0,
            offset: 10
        )

        #expect(selection.selectedText(in: ["Select recognized words"]) == "recognized")
    }

    @Test func lineSelectionIncludesTheWholeLine() {
        let selection = OCRTextSelection.lineSelection(in: "whole line", lineIndex: 1)

        #expect(selection.selectedText(in: ["unused", "whole line"]) == "whole line")
    }

    @Test func composedCharactersUseUTF16Boundaries() {
        let text = "A👨‍👩‍👧‍👦中文B"
        let familyRange = (text as NSString).range(of: "👨‍👩‍👧‍👦")
        let selection = OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: 0, offset: familyRange.location),
            extent: OCRTextPosition(lineIndex: 0, offset: NSMaxRange(familyRange))
        )

        #expect(selection.selectedText(in: [text]) == "👨‍👩‍👧‍👦")
    }

    @Test func containsWorksForReversedSelections() {
        let selection = OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: 2, offset: 4),
            extent: OCRTextPosition(lineIndex: 0, offset: 2)
        )

        #expect(selection.contains(OCRTextPosition(lineIndex: 1, offset: 0)))
        #expect(!selection.contains(OCRTextPosition(lineIndex: 2, offset: 5)))
    }

    @Test func lineBreakOnlySelectionIsPreserved() {
        let lines = ["first", "second"]
        let selection = OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: 0, offset: 5),
            extent: OCRTextPosition(lineIndex: 1, offset: 0)
        )

        #expect(selection.selectedText(in: lines) == "\n")
    }
}
