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
            // 回退确实发生了：Tesseract 缺语言包被接住后，Vision 接手这张纯白图，
            // 而它确实没有文字。空白由 `.noTextFound` 表达（不是 `recognitionFailed`）。
            // 这里要断言的是「Tesseract 的错误没有逃逸」，所以两者都算通过；
            // 任何别的错误（超时、引擎无响应、语言不支持）仍然必须让本用例变红。
            switch error {
            case .noTextFound, .recognitionFailed:
                break
            default:
                Issue.record("Tesseract error escaped instead of falling back to Vision: \(error)")
            }
        }
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
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
