import Foundation

/// A UTF-16 text position inside an ordered OCR line collection.
public struct OCRTextPosition: Sendable, Equatable, Comparable {
    /// Zero-based index of the line that holds the position.
    public let lineIndex: Int
    /// UTF-16 offset within the line, measured in `NSString` units.
    public let offset: Int

    /// Creates a position, clamping both components to zero or greater.
    ///
    /// - Parameters:
    ///   - lineIndex: Zero-based line index.
    ///   - offset: UTF-16 offset within that line.
    public init(lineIndex: Int, offset: Int) {
        self.lineIndex = max(lineIndex, 0)
        self.offset = max(offset, 0)
    }

    /// Orders positions by line first, then by offset inside the line.
    public static func < (lhs: OCRTextPosition, rhs: OCRTextPosition) -> Bool {
        lhs.lineIndex == rhs.lineIndex
            ? lhs.offset < rhs.offset
            : lhs.lineIndex < rhs.lineIndex
    }
}

/// The selected UTF-16 range for one OCR line.
public struct OCRTextSelectionSlice: Sendable, Equatable {
    /// Zero-based index of the OCR line this slice belongs to.
    public let lineIndex: Int
    /// UTF-16 location where the selected range starts in the line.
    public let location: Int
    /// Number of UTF-16 units selected in the line.
    public let length: Int

    /// Creates a slice from a line index and an already-clamped UTF-16 range.
    ///
    /// - Parameters:
    ///   - lineIndex: Zero-based index of the line.
    ///   - location: UTF-16 start offset inside the line.
    ///   - length: Number of UTF-16 units selected.
    public init(lineIndex: Int, location: Int, length: Int) {
        self.lineIndex = lineIndex
        self.location = location
        self.length = length
    }

    /// The selected range as an `NSRange` over the line's UTF-16 storage.
    public var range: NSRange {
        NSRange(location: location, length: length)
    }
}

/// A Word-style selection that can span multiple ordered OCR lines.
public struct OCRTextSelection: Sendable, Equatable {
    /// The end that stays fixed while the user extends the selection.
    public var anchor: OCRTextPosition
    /// The end that follows the pointer or caret.
    public var extent: OCRTextPosition

    /// Creates a selection between two endpoints.
    ///
    /// The endpoints may be given in either order; ``orderedEndpoints`` sorts them
    /// when a range is needed.
    ///
    /// - Parameters:
    ///   - anchor: The fixed endpoint.
    ///   - extent: The moving endpoint.
    public init(anchor: OCRTextPosition, extent: OCRTextPosition) {
        self.anchor = anchor
        self.extent = extent
    }

    /// Whether the anchor and extent are the same position, so nothing is selected.
    public var isEmpty: Bool {
        anchor == extent
    }

    /// The endpoints sorted from earliest to latest.
    public var orderedEndpoints: (start: OCRTextPosition, end: OCRTextPosition) {
        anchor <= extent ? (anchor, extent) : (extent, anchor)
    }

    /// Whether `position` lies between the two endpoints, endpoints included.
    ///
    /// - Parameter position: The position to test.
    /// - Returns: `true` when the position is inside the selection.
    public func contains(_ position: OCRTextPosition) -> Bool {
        let endpoints = orderedEndpoints
        return position >= endpoints.start && position <= endpoints.end
    }

    /// Splits the selection into one UTF-16 range per covered line.
    ///
    /// The start offset applies only to the first covered line and the end offset
    /// only to the last; lines in between select their entire content. Line indices
    /// past the end of `lines` are clamped to the last line, and offsets past a
    /// line's length are clamped to its end, so malformed positions never trap.
    ///
    /// - Parameter lines: The recognized lines in reading order.
    /// - Returns: Slices in ascending line order, or an empty array when there are
    ///   no lines or the clamped range is inverted.
    public func slices(in lines: [String]) -> [OCRTextSelectionSlice] {
        guard !lines.isEmpty else { return [] }
        let endpoints = orderedEndpoints
        let startLine = min(endpoints.start.lineIndex, lines.count - 1)
        let endLine = min(endpoints.end.lineIndex, lines.count - 1)
        guard startLine <= endLine else { return [] }

        return (startLine...endLine).map { lineIndex in
            let lineLength = (lines[lineIndex] as NSString).length
            let location =
                lineIndex == startLine
                ? min(endpoints.start.offset, lineLength)
                : 0
            let upperBound =
                lineIndex == endLine
                ? min(endpoints.end.offset, lineLength)
                : lineLength
            return OCRTextSelectionSlice(
                lineIndex: lineIndex,
                location: location,
                length: max(upperBound - location, 0)
            )
        }
    }

    /// Returns the selected text, one entry per covered line joined with a newline.
    ///
    /// Empty per-line selections contribute an empty string, so blank lines inside
    /// the range stay visible in the result instead of being collapsed.
    ///
    /// - Parameter lines: The recognized lines in reading order.
    /// - Returns: The selected substrings joined with `"\n"`.
    public func selectedText(in lines: [String]) -> String {
        slices(in: lines).compactMap { slice in
            guard lines.indices.contains(slice.lineIndex) else { return nil }
            return slice.length > 0
                ? (lines[slice.lineIndex] as NSString).substring(with: slice.range)
                : ""
        }.joined(separator: "\n")
    }

    /// Builds a selection covering the word at `offset`.
    ///
    /// Word boundaries come from word enumeration over `text`. An offset that is
    /// not inside a word, including one on whitespace, falls back to the composed
    /// character sequence at the clamped offset; empty text yields a collapsed
    /// selection at offset zero. Offsets and the resulting extent are UTF-16 units.
    ///
    /// - Parameters:
    ///   - text: The line to search.
    ///   - lineIndex: Line index recorded in the resulting positions.
    ///   - offset: UTF-16 offset near the word to select.
    /// - Returns: A selection whose extent ends just past the word.
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

    /// Builds a selection covering an entire line.
    ///
    /// - Parameters:
    ///   - text: The line whose length defines the extent.
    ///   - lineIndex: Line index recorded in the resulting positions.
    /// - Returns: A selection from offset zero to the line's UTF-16 length.
    public static func lineSelection(in text: String, lineIndex: Int) -> OCRTextSelection {
        OCRTextSelection(
            anchor: OCRTextPosition(lineIndex: lineIndex, offset: 0),
            extent: OCRTextPosition(lineIndex: lineIndex, offset: (text as NSString).length)
        )
    }
}
