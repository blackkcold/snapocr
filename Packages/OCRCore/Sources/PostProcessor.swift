import Foundation

/// Applies the text cleanup rules shared by the OCR engines.
///
/// The pass trims surrounding whitespace from every recognized line and rebuilds
/// the aggregate text from the trimmed lines, so engines that pad lines or leave
/// stray blank space produce comparable output. Geometry, confidence, engine
/// type, layout flag, and timing are carried through unchanged.
public struct PostProcessor: Sendable {

    /// Creates a stateless post-processor; every rule runs per call.
    public init() {}

    /// Returns a copy of `result` with each observation's text trimmed.
    ///
    /// Trimming removes leading and trailing whitespace and newlines from each
    /// line. The aggregate `text` is then rebuilt by joining the trimmed lines
    /// with newlines; when there are no observations, the original aggregate text
    /// is kept. Lines that trim to nothing remain as blank entries.
    ///
    /// - Parameter result: The raw engine result to normalize.
    /// - Returns: A result with the same metadata and cleaned text.
    public func process(_ result: OCRResult) -> OCRResult {
        let observations = result.observations.map { line in
            OCRLine(
                text: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
                confidence: line.confidence,
                boundingBox: line.boundingBox
            )
        }
        return OCRResult(
            text: observations.isEmpty ? result.text : observations.map(\.text).joined(separator: "\n"),
            confidence: result.confidence,
            engineType: result.engineType,
            layoutPreserved: result.layoutPreserved,
            observations: observations,
            processingTimeMs: result.processingTimeMs
        )
    }

    /// Finds links in `text` using `NSDataDetector`.
    ///
    /// - Parameter text: The text to scan, typically recognized OCR output.
    /// - Returns: Absolute URLs in the order they appear, or an empty array when
    ///   the detector cannot be created or nothing matches.
    public func detectURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
    }
}
