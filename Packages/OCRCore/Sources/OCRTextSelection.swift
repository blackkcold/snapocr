import Foundation

/// A UTF-16 text position inside an ordered OCR line collection.
public struct OCRTextPosition: Sendable, Equatable, Comparable {
    public let lineIndex: Int
    public let offset: Int

    public init(lineIndex: Int, offset: Int) {
        self.lineIndex = max(lineIndex, 0)
        self.offset = max(offset, 0)
    }

    public static func < (lhs: OCRTextPosition, rhs: OCRTextPosition) -> Bool {
        lhs.lineIndex == rhs.lineIndex
            ? lhs.offset < rhs.offset
            : lhs.lineIndex < rhs.lineIndex
    }
}

/// The selected UTF-16 range for one OCR line.
public struct OCRTextSelectionSlice: Sendable, Equatable {
    public let lineIndex: Int
    public let location: Int
    public let length: Int

    public init(lineIndex: Int, location: Int, length: Int) {
        self.lineIndex = lineIndex
        self.location = location
        self.length = length
    }

    public var range: NSRange {
        NSRange(location: location, length: length)
    }
}

/// A Word-style selection that can span multiple ordered OCR lines.
public struct OCRTextSelection: Sendable, Equatable {
    public var anchor: OCRTextPosition
    public var extent: OCRTextPosition

    public init(anchor: OCRTextPosition, extent: OCRTextPosition) {
        self.anchor = anchor
        self.extent = extent
    }

    public var isEmpty: Bool {
        anchor == extent
    }

    public var orderedEndpoints: (start: OCRTextPosition, end: OCRTextPosition) {
        anchor <= extent ? (anchor, extent) : (extent, anchor)
    }

    public func contains(_ position: OCRTextPosition) -> Bool {
        let endpoints = orderedEndpoints
        return position >= endpoints.start && position <= endpoints.end
    }

    public func slices(in lines: [String]) -> [OCRTextSelectionSlice] {
        guard !lines.isEmpty else { return [] }
        let endpoints = orderedEndpoints
        let startLine = min(endpoints.start.lineIndex, lines.count - 1)
        let endLine = min(endpoints.end.lineIndex, lines.count - 1)
        guard startLine <= endLine else { return [] }

        return (startLine...endLine).map { lineIndex in
            let lineLength = (lines[lineIndex] as NSString).length
            let location = lineIndex == startLine
                ? min(endpoints.start.offset, lineLength)
                : 0
            let upperBound = lineIndex == endLine
                ? min(endpoints.end.offset, lineLength)
                : lineLength
            return OCRTextSelectionSlice(
                lineIndex: lineIndex,
                location: location,
                length: max(upperBound - location, 0)
            )
        }
    }

    public func selectedText(in lines: [String]) -> String {
        slices(in: lines).compactMap { slice in
            guard lines.indices.contains(slice.lineIndex) else { return nil }
            return slice.length > 0
                ? (lines[slice.lineIndex] as NSString).substring(with: slice.range)
                : ""
        }.joined(separator: "\n")
    }

    public static func wordSelection(
        in text: String,
        lineIndex: Int,
        offset: Int
    ) -> OCRTextSelection {
        let nsText = text as NSString
        guard nsText.length > 0 else {
            let position = OCRTextPosition(lineIndex: lineIndex, offset: 0)
            return OCRTextSelection(anchor: position, extent: position)
        }

        let safeOffset = min(max(offset, 0), nsText.length - 1)
        var selectedRange: NSRange?
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, substringRange, _, stop in
            let range = NSRange(substringRange, in: text)
            if NSLocationInRange(safeOffset, range) {
                selectedRange = range
                stop = true
            }
        }

        let range = selectedRange ?? nsText.rangeOfComposedCharacterSequence(at: safeOffset)
        return OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: lineIndex, offset: range.location),
            extent: OCRTextPosition(lineIndex: lineIndex, offset: NSMaxRange(range))
        )
    }

    public static func lineSelection(in text: String, lineIndex: Int) -> OCRTextSelection {
        OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: lineIndex, offset: 0),
            extent: OCRTextPosition(lineIndex: lineIndex, offset: (text as NSString).length)
        )
    }
}
