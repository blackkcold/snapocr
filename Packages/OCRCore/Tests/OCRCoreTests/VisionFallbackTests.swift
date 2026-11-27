import CoreGraphics
import Foundation
import Testing

@testable import OCRCore

/// 验证 `.accurate` 优先、缩小重跑补齐与 `.fast` 安全网的编排。
///
/// 这些测试注入假的识别器，不依赖 Vision，因此能在 CI 上真正跑起来。
struct VisionFallbackTests {
    @Test func accurateIsTheDefaultRecognitionLevel() {
        #expect(OCROptions().recognitionLevel == .accurate)
        #expect(OCROptions.fast.recognitionLevel == .fast)
    }

    @Test func usesAccurateResultWhenNoRetryIsNeeded() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level: level)
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

    /// 关键回归：4K 级画布只读到少量标签时，必须以更小的画布重跑同一引擎并采用更完整的结果。
    @Test func rescuesPartiallyLostLinesOnALargeCanvas() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { image, languages, _, level in
            await calls.record(level: level, resolution: image.width, languages: languages)
            // 全幅只读到 3 个标签，缩到 3000 宽后读到 24 个：真实失败形态。
            return image.width >= 3840
                ? [Self.line("通用"), Self.line("外观"), Self.line("快捷键")]
                : Self.chineseLabels
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 3840, height: 2160),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.observations.count == 24)
        #expect(result.text.contains("滚动截图"))
        #expect(result.text.contains("检查更新"))
        let entries = await calls.entries
        #expect(entries.map(\.resolution) == [3840, 3000])
        // 补齐必须沿用要求的级别与语言：换成 `.fast` 就只剩拉丁乱码。
        #expect(entries.map(\.level) == [.accurate, .accurate])
        #expect(entries.map(\.languages) == [["zh-Hans", "en-US"], ["zh-Hans", "en-US"]])
    }

    /// 缩小重跑只补更完整的结果：全幅已经读到 24 个标签时不再多发请求。
    @Test func doesNotRetryWhenTheCanvasWasReadCompletely() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { image, _, _, _ in
            await calls.record(level: .accurate, resolution: image.width)
            return Self.chineseLabels
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 3840, height: 2160),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.observations.count == 24)
        let resolutions = await calls.resolutions
        #expect(resolutions == [3840])
    }

    /// 重跑没变多时不替换：多认出一点边界不该把整幅结果换掉。
    @Test func keepsWholeCanvasResultWhenTheRetryIsNotClearlyBetter() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { image, _, _, _ in
            await calls.record(level: .accurate, resolution: image.width)
            return image.width >= 3840
                ? [Self.line("通用"), Self.line("外观"), Self.line("快捷键")]
                : [Self.line("通用"), Self.line("外观"), Self.line("快捷键"), Self.line("截图")]
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 3840, height: 2160),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.text == "通用\n外观\n快捷键")
        let resolutions = await calls.resolutions
        #expect(resolutions == [3840, 3000])
    }

    /// 已经分块的大图逐块识别，每块都小于 3000，不该再缩。
    @Test func doesNotRescaleTilesOfAnAlreadyTiledCanvas() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { image, _, _, _ in
            await calls.record(level: .accurate, resolution: image.width)
            return [Self.line("通用")]
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 2048, height: 2048),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.text == "通用")
        let resolutions = await calls.resolutions
        #expect(resolutions == [2048])
    }

    /// 大画布整幅读空时，先缩图重跑，再走 `.fast`。
    ///
    /// 顺序很重要：`.fast` 读不了中文，先缩图能让中文截图靠 `.accurate` 补回来，
    /// 不必等到拉丁兜底。这条同时锁住「缩图结果优先于 fast」。
    @Test func prefersTheSmallerScaleRetryOverFastWhenTheCanvasReadsNothing() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { image, _, _, level in
            await calls.record(level: level, resolution: image.width)
            switch (level, image.width) {
            case (.accurate, 3840...):
                return []
            case (.accurate, _):
                return Self.chineseLabels
            default:
                return [Self.line("latin garbage")]
            }
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 3840, height: 2160),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.observations.count == 24)
        #expect(result.text.contains("滚动截图"))
        let entries = await calls.entries
        #expect(entries.map(\.level) == [.accurate, .accurate])
        #expect(entries.map(\.resolution) == [3840, 3000])
    }

    @Test func retriesWithFastWhenAccurateFindsNothingOnALargeCanvas() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { image, _, _, level in
            await calls.record(level: level, resolution: image.width)
            return level == .fast ? [Self.line("recovered anchor")] : []
        }

        let result = try await engine.recognize(
            image: try Self.makeImage(width: 1600, height: 1300),
            languages: ["zh-Hans", "en-US"],
            options: OCROptions()
        )

        #expect(result.text == "recovered anchor")
        let entries = await calls.entries
        #expect(entries.map(\.level) == [.accurate, .fast])
    }

    @Test func keepsAccurateResultWhenFastFindsMoreCharacters() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level: level)
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

    /// `.fast` 兜底失败时保持「没有文字」的语义，让分块路径把这一块当空白跳过。
    ///
    /// 复核实测过：这里重抛 `.fast` 的错误会让分块路径认不出空白块，一块坏图就会
    /// 让整张 5K 截图失败。判据是错误结构（``OCRError/isNoText``），不是文案。
    @Test func keepsNoTextSemanticsWhenTheFastRetryFails() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level: level)
            guard level == .accurate else {
                throw OCRError.recognitionFailed(reason: "Vision 框架识别失败: injected")
            }
            return []
        }

        do {
            _ = try await engine.recognize(
                image: try Self.makeImage(width: 1600, height: 1300),
                languages: ["zh-Hans", "en-US"],
                options: OCROptions()
            )
            Issue.record("expected the empty result to throw")
        } catch let error as OCRError {
            #expect(error.isNoText)
            guard case .noTextFound = error else {
                Issue.record("unexpected OCR error case: \(error)")
                return
            }
        }

        let levels = await calls.levels
        #expect(levels == [.accurate, .fast])
    }

    @Test func doesNotRetryOnSmallCrops() async throws {
        let calls = RecognitionCalls()
        let engine = VisionOCREngine { _, _, _, level in
            await calls.record(level: level)
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

    /// 缩小重跑的触发条件：只有「大画布 + 结果明显偏少」才重跑。
    ///
    /// 参数表同时锁住两侧：正常密度的 4K 结果、已是分块尺寸的块、以及本来就小的
    /// 裁切都不重跑，避免对普通截图误触发。
    @Test(arguments: [
        // 4K 丢行：3 个标签 = 6 字符 / 8.29Mpx = 0.72 字符/Mpx
        (6, 3840, 2160, true),
        // 4K 读到 24 个标签 = 55 字符 / 8.29Mpx = 6.63 字符/Mpx
        (55, 3840, 2160, false),
        // 4K 上只有一个三按钮对话框：稀疏但正常，仍会重跑一次（结果不多就不采用）
        (6, 3840, 2160, true),
        // 已经分块的尺寸：每块 <= 2048，不再缩
        (6, 2048, 2048, false),
        // 小裁切：没有可缩的余量
        (6, 1600, 1300, false),
        // 长边刚好 3000：已经处于目标尺寸
        (6, 3000, 1688, false),
        // 超过分块阈值：由 OCRPipeline 分块，不走缩小重跑
        (6, 5120, 2880, false),
    ])
    func rescalePolicyDependsOnDensityAndCanvasSize(
        characterCount: Int,
        width: Int,
        height: Int,
        expected: Bool
    ) {
        #expect(
            VisionRecognitionPolicy.shouldRetryAtSmallerScale(
                characterCount: characterCount,
                imageWidth: width,
                imageHeight: height
            ) == expected
        )
    }

    @Test(arguments: [
        // 全幅 0 字符 → 重跑读到内容，采用
        (0, 55, true),
        // 全幅 6 字符 → 重跑 55 字符，明显更完整，采用
        (6, 55, true),
        // 全幅 6 字符 → 重跑 9 字符，不到翻倍，保留全幅
        (6, 9, false),
        // 全幅 6 字符 → 重跑 12 字符，正好翻倍，采用
        (6, 12, true),
        // 重跑更少，保留全幅
        (55, 6, false),
        // 重跑为空，保留全幅
        (6, 0, false),
    ])
    func smallerScaleResultIsAdoptedOnlyWhenClearlyMoreComplete(
        primaryCharacters: Int,
        retryCharacters: Int,
        expected: Bool
    ) {
        #expect(
            VisionRecognitionPolicy.prefersSmallerScaleResult(
                primary: Self.lines(characterCount: primaryCharacters),
                retry: Self.lines(characterCount: retryCharacters)
            ) == expected
        )
    }

    // MARK: - 辅助

    /// 24 个真实中文界面标签，用于模拟「读到 24/24」的结果。
    private static let chineseLabels: [OCRLine] = [
        "通用", "外观", "快捷键", "截图", "录屏", "检查更新",
        "剪贴板", "历史", "资料库", "标注", "滚动截图", "窗口",
        "导出", "分享", "设置", "关于", "帮助", "反馈",
        "隐私", "性能", "语言", "识别", "文字", "工具",
    ].map(line)

    private static func line(_ text: String) -> OCRLine {
        OCRLine(text: text, confidence: 0.9, boundingBox: .zero)
    }

    /// 生成恰好 `characterCount` 个非空白字符的行，用 `x` 填充。
    private static func lines(characterCount: Int) -> [OCRLine] {
        guard characterCount > 0 else { return [] }
        return [line(String(repeating: "x", count: characterCount))]
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

private actor RecognitionCalls {
    struct Entry: Sendable {
        let level: OCRRecognitionLevel
        let resolution: Int
        let languages: [String]
    }

    private(set) var entries: [Entry] = []

    var levels: [OCRRecognitionLevel] { entries.map(\.level) }
    var resolutions: [Int] { entries.map(\.resolution) }

    func record(level: OCRRecognitionLevel) {
        entries.append(Entry(level: level, resolution: 0, languages: []))
    }

    func record(level: OCRRecognitionLevel, resolution: Int, languages: [String] = []) {
        entries.append(Entry(level: level, resolution: resolution, languages: languages))
    }
}
