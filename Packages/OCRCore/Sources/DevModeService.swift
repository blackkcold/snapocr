import CoreGraphics
import Foundation

// MARK: - 开发者模式服务

/// 开发者模式服务，用于对比 Vision 和 Tesseract 两个 OCR 引擎的识别效果。
///
/// 通过 `UserDefaults` 的 `snapglass.devMode.enabled` 控制启用状态（默认关闭）。
/// 启用后，每次 OCR 请求会并行运行 Vision 和 Tesseract 两个引擎，
/// 记录对比结果和性能数据，支持日志导出为 JSON 格式供开发者分析。
///
/// ## 使用示例
/// ```swift
/// let devMode = DevModeService.shared
/// devMode.isEnabled = true
///
/// let result = await devMode.compareEngines(
///     image: cgImage,
///     languages: ["zh-Hans", "en"]
/// )
/// print("Vision: \(result.vision.text)")
/// print("Tesseract: \(result.tesseract.text)")
/// print("文本一致: \(result.isTextMatch)")
/// ```
///
/// ## JSON 日志导出
/// ```swift
/// let jsonData = await devMode.exportLogs()
/// try jsonData.write(to: URL(fileURLWithPath: "/tmp/devmode-logs.json"))
/// ```
public actor DevModeService {

    // MARK: - 单例

    /// 共享实例。
    public static let shared = DevModeService()

    // MARK: - 常量

    /// UserDefaults 中开发者模式的键。
    private let enableKey = "snapglass.devMode.enabled"

    /// 最大日志条目数，超过时自动移除最旧的条目。
    private let maxLogEntries = 1000

    // MARK: - 属性

    /// 开发者模式是否启用。
    ///
    /// 通过 `UserDefaults` 持久化存储，可在偏好设置或 CLI 中切换。
    /// 默认值为 `false`。
    ///
    /// ```swift
    /// // 启用开发者模式
    /// DevModeService.shared.isEnabled = true
    ///
    /// // 检查状态
    /// if DevModeService.shared.isEnabled { ... }
    /// ```
    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enableKey) }
        set { UserDefaults.standard.set(newValue, forKey: enableKey) }
    }

    /// 日志条目数组。
    ///
    /// 存储所有引擎对比的日志记录，达到 `maxLogEntries` 上限时自动裁剪。
    private var logEntries: [OCRLogEntry] = []

    /// 当前日志条目数量。
    public var logCount: Int {
        logEntries.count
    }

    // MARK: - 私有初始化

    private init() {}

    // MARK: - 引擎对比

    /// 并行运行 Vision 和 Tesseract 两个 OCR 引擎，返回对比结果。
    ///
    /// 调用此方法前应检查 `isEnabled`，仅在开发者模式启用时执行。
    /// 如果某个引擎识别失败，会返回包含空文本和零置信度的结果，
    /// 确保对比流程始终可用。
    ///
    /// - Parameters:
    ///   - image: 要识别的图像（CGImage）
    ///   - languages: 语言优先级列表，按顺序尝试识别
    /// - Returns: 包含两个引擎识别结果和日志条目的 `DevCompareResult`
    public func compareEngines(
        image: CGImage,
        languages: [String]
    ) async -> DevCompareResult {
        async let visionResult = recognizeWithVision(image: image, languages: languages)
        async let tesseractResult = recognizeWithTesseract(image: image, languages: languages)

        let (vision, tesseract) = await (visionResult, tesseractResult)

        let entry = OCRLogEntry(
            timestamp: Date(),
            visionConfidence: vision.confidence,
            tesseractConfidence: tesseract.confidence,
            visionText: vision.text,
            tesseractText: tesseract.text,
            visionTimeMs: vision.processingTimeMs,
            tesseractTimeMs: tesseract.processingTimeMs
        )

        // 管理日志容量上限
        logEntries.append(entry)
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }

        return DevCompareResult(vision: vision, tesseract: tesseract, log: entry)
    }

    // MARK: - 日志管理

    /// 导出所有日志为 JSON 格式数据。
    ///
    /// 导出的 JSON 使用 `JSONEncoder` 的 `prettyPrinted` 和 `sortedKeys` 格式，
    /// 日期使用 ISO 8601 格式编码。
    ///
    /// - Returns: JSON 格式的日志数据，如果编码失败则返回空数据
    public func exportLogs() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(logEntries)
        } catch {
            return Data()
        }
    }

    /// 清除所有日志。
    public func clearLogs() {
        logEntries.removeAll()
    }

    // MARK: - 私有识别方法

    /// 使用 Vision 引擎识别图像。
    ///
    /// 失败时返回空结果（空文本、零置信度），确保对比流程不中断。
    private func recognizeWithVision(
        image: CGImage,
        languages: [String]
    ) async -> OCRResult {
        let engine = VisionOCREngine()
        let options = OCROptions(languages: languages)
        do {
            return try await engine.recognize(
                image: image,
                languages: languages,
                options: options
            )
        } catch {
            return OCRResult(
                text: "",
                confidence: 0,
                engineType: .vision,
                layoutPreserved: options.preserveLayout,
                observations: [],
                processingTimeMs: 0
            )
        }
    }

    /// 使用 Tesseract 引擎识别图像。
    ///
    /// 失败时返回空结果（空文本、零置信度），确保对比流程不中断。
    private func recognizeWithTesseract(
        image: CGImage,
        languages: [String]
    ) async -> OCRResult {
        let engine = TesseractOCREngine()
        let options = OCROptions(languages: languages)
        do {
            return try await engine.recognize(
                image: image,
                languages: languages,
                options: options
            )
        } catch {
            return OCRResult(
                text: "",
                confidence: 0,
                engineType: .tesseract(languageDataPath: nil),
                layoutPreserved: false,
                observations: [],
                processingTimeMs: 0
            )
        }
    }
}
