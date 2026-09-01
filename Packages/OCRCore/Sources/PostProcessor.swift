import Foundation

public struct PostProcessor: Sendable {

    public init() {}

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

    public func detectURLs(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
    }
}
