import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import OCRCore

struct VisionIntegrationTests {
    @Test func recognizesGeneratedTextWithInteractiveBounds() async throws {
        let image = try makeTextImage("SNAPGLASS 123")
        let result = try await OCRPipeline().recognize(
            image,
            options: OCROptions(
                languages: ["en-US"],
                minConfidence: 0.1,
                preserveLayout: true
            )
        )

        #expect(result.text.uppercased().contains("SNAPGLASS"))
        #expect(result.observations.contains { !$0.editorBoundingBox.isEmpty })
    }

    private func makeTextImage(_ text: String) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 900,
            height: 220,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OCRError.recognitionFailed(reason: "Unable to create test context")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 220))

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 92, nil),
                .foregroundColor: CGColor(gray: 0, alpha: 1),
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw OCRError.recognitionFailed(reason: "Unable to create test image")
        }
        return image
    }
}
