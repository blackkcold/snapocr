import AppIntents
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import BarcodeCore
import CaptureCore
import OCRCore

// MARK: - App Intents for Shortcuts Integration
//
// Phase 2: 4 个核心 Shortcuts Action，支持在 Shortcuts.app 中发现和使用。
// 所有 intent 均标注 `openAppWhenRun = true` 以确保权限上下文（屏幕录制、辅助功能等）。

// MARK: - Shared Helpers

/// 将 `CGImage` 保存为 PNG 到临时目录，返回文件路径。
/// 用于截图类 intent 返回可传递的文件路径给 Shortcuts workflow。
private func saveCGImageToTempPNG(_ image: CGImage, label: String) throws -> String {
    let tempDir = FileManager.default.temporaryDirectory
    let filename = "snapglass-\(label)-\(UUID().uuidString).png"
    let fileURL = tempDir.appendingPathComponent(filename)

    guard let destination = CGImageDestinationCreateWithURL(
        fileURL as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw AppIntentsError(
            message: "无法创建图片写入目标: \(fileURL.path)"
        )
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw AppIntentsError(
            message: "PNG 写入失败: \(fileURL.path)"
        )
    }
    return fileURL.path
}

/// 从文件路径加载 `CGImage`。
/// 支持 PNG、JPEG、HEIC、TIFF、BMP 等常见格式。
private func loadCGImage(from path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw AppIntentsError(message: "无法打开图片文件: \(path)")
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw AppIntentsError(message: "无法解码图片: \(path)")
    }
    return image
}

// MARK: - App Intents 通用错误

/// 可传递给 Shortcuts 的错误类型。
/// 遵循 `LocalizedError` 以便 Shortcuts 显示本地化错误信息。
struct AppIntentsError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

// MARK: - 1. Capture Area Intent

/// 区域截图 intent —— 在 Shortcuts 中可发现为 "Capture Area"。
///
/// 触发后会打开 SnapGlass 应用，执行区域截图（默认捕获主显示器全区域），
/// 并将结果保存为临时 PNG 文件返回路径。
///
/// 使用方式：
/// ```shortcuts
/// Capture Area
///   → 输出: 截图文件路径 (String)
/// ```
public struct CaptureAreaIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture Area"

    public static let description = IntentDescription(
        "捕获屏幕选定区域的截图并保存为图片文件。",
        categoryName: "工具",
        searchKeywords: ["screenshot", "capture", "area", "region", "截图", "区域"]
    )

    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let orchestrator = CaptureOrchestrator()

        // 检查权限
        guard await orchestrator.checkPermissionStatus() else {
            throw AppIntentsError(message: "屏幕录制权限未授权，请在系统设置中允许 SnapGlass 访问。")
        }

        let result = try await orchestrator.capture(
            mode: .area(CGDisplayBounds(CGMainDisplayID())),
            options: CaptureOptions(includeCursor: false)
        )

        let filePath = try saveCGImageToTempPNG(result.image, label: "area")

        return .result(value: filePath)
    }
}

// MARK: - 2. Capture Fullscreen Intent

/// 全屏截图 intent —— 在 Shortcuts 中可发现为 "Capture Fullscreen"。
///
/// 触发后打开 SnapGlass 应用，捕获主显示器完整画面，
/// 并将结果保存为临时 PNG 文件返回路径。
public struct CaptureFullscreenIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture Fullscreen"

    public static let description = IntentDescription(
        "捕获整个屏幕的截图并保存为图片文件。",
        categoryName: "工具",
        searchKeywords: ["screenshot", "capture", "fullscreen", "full", "截图", "全屏"]
    )

    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let orchestrator = CaptureOrchestrator()

        guard await orchestrator.checkPermissionStatus() else {
            throw AppIntentsError(message: "屏幕录制权限未授权，请在系统设置中允许 SnapGlass 访问。")
        }

        let result = try await orchestrator.capture(
            mode: .fullscreen,
            options: CaptureOptions()
        )

        let filePath = try saveCGImageToTempPNG(result.image, label: "fullscreen")

        return .result(value: filePath)
    }
}

// MARK: - 3. OCR Image Intent

/// OCR 文字识别 intent —— 在 Shortcuts 中可发现为 "OCR Image"。
///
/// 接收一个图片文件路径作为输入，使用 Apple Vision 引擎识别图片中的文字，
/// 返回识别出的文本内容。
public struct RecognizeTextIntent: AppIntent {
    public static let title: LocalizedStringResource = "OCR Image"

    public static let description = IntentDescription(
        "识别图片中的文字内容，支持中英文等多语言。",
        categoryName: "工具",
        searchKeywords: ["ocr", "text", "recognize", "文字", "识别"]
    )

    public static let openAppWhenRun: Bool = true

    @Parameter(
        title: "图片文件路径",
        description: "要识别的图片文件路径（支持 PNG、JPEG、HEIC 等格式）"
    )
    public var imagePath: URL

    @Parameter(
        title: "识别语言",
        description: "优先识别的语言列表，如 zh-Hans（简体中文）、en（英语），留空自动检测",
        default: []
    )
    public var languages: [String]

    public init() {
        self.imagePath = URL(fileURLWithPath: "")
        self.languages = []
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cgImage = try loadCGImage(from: imagePath.path)

        let langs = languages.isEmpty ? ["zh-Hans", "en"] : languages
        let options = OCROptions(languages: langs)

        let pipeline = OCRPipeline(options: options)
        let result = try await pipeline.recognize(cgImage)

        return .result(value: result.text)
    }
}

// MARK: - 4. Scan Barcode Intent

/// 条码扫描 intent —— 在 Shortcuts 中可发现为 "Scan Barcode"。
///
/// 接收一个图片文件路径作为输入，使用 Apple Vision 引擎检测并解码图片中的条码/二维码，
/// 返回解码后的内容（如 URL、文本等）。
public struct ScanBarcodeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Scan Barcode"

    public static let description = IntentDescription(
        "扫描图片中的二维码或条形码并解码其内容。",
        categoryName: "工具",
        searchKeywords: ["barcode", "qr", "scan", "条码", "二维码", "扫描"]
    )

    public static let openAppWhenRun: Bool = true

    @Parameter(
        title: "图片文件路径",
        description: "包含条码或二维码的图片文件路径"
    )
    public var imagePath: URL

    public init() {
        self.imagePath = URL(fileURLWithPath: "")
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cgImage = try loadCGImage(from: imagePath.path)

        let engine = VisionBarcodeEngine()
        let results = try await engine.detect(in: cgImage, types: [])

        guard let first = results.first else {
            throw AppIntentsError(message: "未在图片中检测到条码或二维码。")
        }

        let output: String
        if results.count > 1 {
            output = results.map { "[\($0.type.rawValue)] \($0.payload)" }
                .joined(separator: "\n")
        } else {
            output = "\(first.payload) (\(first.type.rawValue))"
        }

        return .result(value: output)
    }
}

// MARK: - 5. Search History Intent (Supplementary)

/// 截图历史搜索 intent —— 在 Shortcuts 中可发现为 "Search History"。
///
/// 在本地截图历史缓存中搜索匹配关键词的条目。
public struct SearchHistoryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Search History"

    public static let description = IntentDescription(
        "在截图历史记录中搜索包含指定关键词的条目。",
        categoryName: "工具",
        searchKeywords: ["history", "search", "history", "搜索", "历史"]
    )

    public static let openAppWhenRun: Bool = true

    @Parameter(
        title: "搜索关键词",
        description: "用于搜索截图历史的文本关键词"
    )
    public var query: String

    public init() {
        self.query = ""
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // 历史搜索功能依赖 HistoryCore 的完整实现，当前返回占位结果。
        // TODO: 接入 HistoryCore 的全文搜索能力
        return .result(
            value: "暂无历史记录。（搜索关键词: \(query)）"
        )
    }
}

// MARK: - App Shortcuts Provider

/// 向 Shortcuts app 注册全部 App Intents，使其在 Shortcuts 中可发现和调用。
///
/// 每个 `AppShortcut` 定义:
/// - `intent`: 对应的 Intent 结构体
/// - `phrases`: 用户的自然语言触发短语（`\(.applicationName)` 会被替换为应用名）
/// - `shortTitle`: Shortcuts 中显示的精简标题
/// - `systemImageName`: SF Symbol 图标
///
/// 注册后，用户可在 Shortcuts.app 中搜索 "Capture Area" "OCR Image" 等
/// 关键词来创建自动化 workflow。
public struct SnapGlassShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureAreaIntent(),
            phrases: [
                "Capture area with \(.applicationName)",
                "Take area screenshot with \(.applicationName)",
                "区域截图 (\(.applicationName))"
            ],
            shortTitle: "Capture Area",
            systemImageName: "camera.viewfinder"
        )

        AppShortcut(
            intent: CaptureFullscreenIntent(),
            phrases: [
                "Capture fullscreen with \(.applicationName)",
                "Take fullscreen screenshot with \(.applicationName)",
                "全屏截图 (\(.applicationName))"
            ],
            shortTitle: "Capture Fullscreen",
            systemImageName: "rectangle.dashed"
        )

        AppShortcut(
            intent: RecognizeTextIntent(),
            phrases: [
                "OCR image with \(.applicationName)",
                "Recognize text in image with \(.applicationName)",
                "图片文字识别 (\(.applicationName))"
            ],
            shortTitle: "OCR Image",
            systemImageName: "text.viewfinder"
        )

        AppShortcut(
            intent: ScanBarcodeIntent(),
            phrases: [
                "Scan barcode with \(.applicationName)",
                "Scan QR code with \(.applicationName)",
                "扫描条码 (\(.applicationName))"
            ],
            shortTitle: "Scan Barcode",
            systemImageName: "qrcode"
        )
    }
}
