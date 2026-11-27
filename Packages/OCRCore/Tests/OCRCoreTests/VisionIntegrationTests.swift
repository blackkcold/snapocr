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

    /// 中文锚点必须真的被识别出来，行数不作为判据。
    ///
    /// `.fast` 级别不支持中日韩：这里同时锁住默认 `.accurate` 与默认中文优先。
    @Test func accurateRecognitionReadsChineseAnchors() async throws {
        let image = try makeTextImage(
            width: 1600,
            height: 900,
            entries: [
                ("截图工具栏", CGPoint(x: 80, y: 520)),
                ("识别文字", CGPoint(x: 80, y: 300)),
            ],
            fontSize: 96,
            fontName: "PingFangSC-Regular"
        )
        let result = try await OCRPipeline().recognize(
            image,
            options: OCROptions(languages: ["zh-Hans", "en-US"], minConfidence: 0.1)
        )

        #expect(result.text.contains("截图"))
        #expect(result.text.contains("识别"))
    }

    /// 4K 画布上，默认 `.accurate` + 中文优先仍能读出中文锚点。
    ///
    /// 这条锁的是默认识别级别与语言顺序（`.fast` 在这里只会给出拉丁乱码），
    /// 不锁回退：220px 的字号远超真实界面，一遍就能读完。真实尺度的部分丢行
    /// 由 `recoversPartiallyLostChineseLabelsOnAFourKCanvas` 覆盖。
    @Test func accurateRecognitionReadsChineseAnchorsOnAFourKCanvas() async throws {
        let image = try makeTextImage(
            width: 3840,
            height: 2160,
            entries: [
                ("截图工具栏", CGPoint(x: 120, y: 1400)),
                ("识别文字", CGPoint(x: 120, y: 900)),
            ],
            fontSize: 220,
            fontName: "PingFangSC-Regular"
        )
        let result = try await OCRPipeline().recognize(
            image,
            options: OCROptions(languages: ["zh-Hans", "en-US"], minConfidence: 0.1)
        )

        #expect(result.text.contains("截图"))
        #expect(result.text.contains("识别"))
    }

    /// 4K 画布 + 真实界面字号（13pt 的 @2x = 26px）下，`.accurate` 会把整幅图的
    /// 大部分文本行静默丢掉：实测 24 个中文标签只返回 3 个。这条不走分块
    /// （3840 < `MemoryGuard.maxImageWidth`），所以它直接锁住「缩小重跑补齐」。
    ///
    /// 断言的是锚点命中数，不是行数：同一行被拆成多段会让行数虚高，命中数才
    /// 反映「读到了多少标签」。临时关掉缩小重跑时这条会红。
    @Test func recoversPartiallyLostChineseLabelsOnAFourKCanvas() async throws {
        let image = try makeLabelGridImage(width: 3840, height: 2160, fontSize: 26)
        let result = try await OCRPipeline().recognize(
            image,
            options: OCROptions(languages: ["zh-Hans", "en-US"], minConfidence: 0.1)
        )

        let hits = Self.interfaceLabels.count { result.text.contains($0) }
        #expect(hits >= 20, "只读到 \(hits)/\(Self.interfaceLabels.count) 个标签：\(result.text)")
    }

    /// 24 个真实中文界面标签，4 列 6 行铺满整块画布。
    private static let interfaceLabels = [
        "通用", "外观", "快捷键", "截图", "录屏", "检查更新",
        "剪贴板", "历史", "资料库", "标注", "滚动截图", "窗口",
        "导出", "分享", "设置", "关于", "帮助", "反馈",
        "隐私", "性能", "语言", "识别", "文字", "工具",
    ]

    private func makeLabelGridImage(width: Int, height: Int, fontSize: CGFloat) throws -> CGImage {
        var entries: [(String, CGPoint)] = []
        let columns = 4
        for (index, label) in Self.interfaceLabels.enumerated() {
            let column = index % columns
            let row = index / columns
            entries.append(
                (
                    label,
                    CGPoint(x: 80 + CGFloat(column) * 1100, y: CGFloat(height) - 400 - CGFloat(row) * 260)
                ))
        }
        return try makeTextImage(
            width: width,
            height: height,
            entries: entries,
            fontSize: fontSize,
            fontName: "PingFangSC-Regular"
        )
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
        fontSize: CGFloat = 72,
        fontName: String = "Helvetica-Bold"
    ) throws -> CGImage {
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

        for (text, point) in entries {
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: CTFontCreateWithName(fontName as CFString, fontSize, nil),
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
