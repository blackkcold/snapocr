import CoreGraphics
import Foundation
import Testing

@testable import OCRCore

/// 验证 `.accurate` 优先与 `.fast` 安全网的编排。
///
/// 这些测试注入假的识别器，不依赖 Vision，因此能在 CI 上真正跑起来。
struct VisionFallbackTests {
    @Test func accurateIsTheDefaultRecognitionLevel() {
        #expect(OCROptions().recognitionLevel == .accurate)
        #expect(OCROptions.fast.recognitionLevel == .fast)
    }

    @Test func usesAccurateResultWhenNoRetryIsNeeded() async throws {
        let calls = LevelCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level)
            return [Self.line("alpha"), Self.line("beta"), Self.line("gamma")]
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 1600, height: 1300),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.text == "alpha\nbeta\ngamma")
        let levels = await calls.levels
        #expect(levels == [.accurate])
    }

    @Test func retriesWithFastWhenAccurateFindsNothingOnALargeCanvas() async throws {
        let calls = LevelCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level)
            return level == .fast ? [Self.line("recovered anchor")] : []
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 1600, height: 1300),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.text == "recovered anchor")
        let levels = await calls.levels
        #expect(levels == [.accurate, .fast])
    }

    @Test func keepsAccurateResultWhenFastFindsMoreCharacters() async throws {
        let calls = LevelCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level)
            // `.fast` 对中文截图会返回字符数更多的乱码；不能因为它更长就替换。
            return level == .fast
                ? [Self.line("garbage with more characters")]
                : [Self.line("中文"), Self.line("识别")]
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 2000, height: 1100),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.text == "中文\n识别")
        let levels = await calls.levels
        #expect(levels == [.accurate])
    }

    @Test func doesNotRetryOnSmallCrops() async throws {
        let calls = LevelCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level)
            return []
        }

        do {
            _ = try await engine.recognize(
                image: try Self.makeImage(width: 300, height: 200),
                languages: ["zh-Hans", "en-US"],
                options: OCROptions()
            )
            Issue.record("expected the empty result to throw")
        } catch is OCRError {
            // expected: 小裁切不做第二次识别
        }

        let levels = await calls.levels
        #expect(levels == [.accurate])
    }

    @Test(arguments: [
        (0, 8_294_400, true),
        (0, 100_000, false),
        (1, 8_294_400, false),
        (2, 8_294_400, false),
        (3, 8_294_400, false),
        (1, 250_000, false),
    ])
    func retryPolicyDependsOnLineCountAndCanvasSize(
        lineCount: Int,
        pixelCount: Int,
        expected: Bool
    ) {
        #expect(
            VisionRecognitionPolicy.shouldRetryWithFast(
                lineCount: lineCount,
                imagePixelCount: pixelCount
            ) == expected
        )
    }

    // MARK: - 辅助

    private static func line(_ text: String) -> OCRLine {
        OCRLine(text: text, confidence: 0.9, boundingBox: .zero)
    }

    private static func makeImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw OCRError.recognitionFailed(reason: "Unable to create test context")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw OCRError.recognitionFailed(reason: "Unable to create test image")
        }
        return image
    }
}

private actor LevelCalls {
    private(set) var levels: [OCRRecognitionLevel] = []

    func record(_ level: OCRRecognitionLevel) {
        levels.append(level)
    }
}
