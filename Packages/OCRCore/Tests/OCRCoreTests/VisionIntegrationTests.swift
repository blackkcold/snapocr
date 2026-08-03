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

    @Test func tiledPipelineRecognizesBothEndsOfWideImage() async throws {
        let image = try makeTextImage(
            width: 4600,
            height: 800,
            entries: [
                ("LEFTANCHOR", CGPoint(x: 80, y: 300)),
                ("RIGHTANCHOR", CGPoint(x: 3500, y: 300)),
            ]
        )
        let result = try await OCRPipeline().recognize(
            image,
            options: OCROptions(languages: ["en-US"], minConfidence: 0.1, preserveLayout: true)
        )

        let uppercased = result.text.uppercased()
        #expect(uppercased.contains("LEFT"))
        #expect(uppercased.contains("RIGHT"))
        #expect(result.observations.contains { $0.text.uppercased().contains("LEFT") && $0.boundingBox.minX < 0.25 })
        #expect(result.observations.contains { $0.text.uppercased().contains("RIGHT") && $0.boundingBox.minX > 0.6 })
    }

    @Test func tiledPipelineRecognizesTopAndBottomOfTallImage() async throws {
        let image = try makeTextImage(
            width: 1000,
            height: 4600,
            entries: [
                ("TOPANCHOR", CGPoint(x: 80, y: 4200)),
                ("BOTTOMANCHOR", CGPoint(x: 80, y: 200)),
            ]
        )
        let result = try await OCRPipeline().recognize(
            image,
            options: OCROptions(languages: ["en-US"], minConfidence: 0.1, preserveLayout: true)
        )

        let uppercased = result.text.uppercased()
        #expect(uppercased.contains("TOP"))
        #expect(uppercased.contains("BOTTOM"))
        #expect(result.observations.contains { $0.text.uppercased().contains("TOP") && $0.boundingBox.minY > 0.7 })
        #expect(result.observations.contains { $0.text.uppercased().contains("BOTTOM") && $0.boundingBox.minY < 0.3 })
    }

    private func makeTextImage(_ text: String) throws -> CGImage {
        try makeTextImage(
            width: 900,
            height: 220,
            entries: [(text, CGPoint(x: 40, y: 70))],
            fontSize: 92
        )
    }

    private func makeTextImage(
        width: Int,
        height: Int,
        entries: [(String, CGPoint)],
        fontSize: CGFloat = 72
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw OCRError.recognitionFailed(reason: "Unable to create test context")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (text, point) in entries {
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
                    .foregroundColor: CGColor(gray: 0, alpha: 1),
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = point
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else {
            throw OCRError.recognitionFailed(reason: "Unable to create test image")
        }
        return image
    }
}
