import CoreGraphics
import Foundation
import Testing

@testable import OCRCore

struct TesseractIntegrationTests {
    @Test func languageMappingDeduplicatesCodes() {
        let codes = TesseractLanguageSupport.tesseractCodes(
            for: ["en-US", "en", "zh-Hans", "ja-JP"]
        )

        #expect(codes == ["eng", "chi_sim", "jpn"])
    }

    @Test func engineHonorsCustomLanguageDataPath() {
        let path = URL(fileURLWithPath: "/tmp/snapglass-missing-tessdata")
        let engine = TesseractOCREngine(languageDataPath: path)

        #expect(engine.engineType == .tesseract(languageDataPath: path))
        #expect(engine.supportedLanguages().isEmpty)
    }

    @Test func unsupportedDownloadLanguageFailsBeforeNetworkAccess() async {
        let downloader = LanguagePackDownloader()

        await #expect(throws: LanguagePackError.self) {
            _ = try await downloader.downloadLanguage("unsupported")
        }
    }

    @Test func pipelineFallsBackToVisionWhenTesseractDataIsMissing() async throws {
        let image = try makeSolidImage(width: 64, height: 64)
        let missingPath = URL(fileURLWithPath: "/tmp/snapglass-missing-tessdata")
        let options = OCROptions(
            languages: ["en-US"],
            engineSelection: .tesseract(languageDataPath: missingPath)
        )

        do {
            let result = try await OCRPipeline().recognize(image, options: options)
            #expect(result.engineType == .vision)
        } catch let error as OCRError {
            guard case .recognitionFailed = error else {
                Issue.record("Tesseract error escaped instead of falling back to Vision: \(error)")
                return
            }
        }
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}
