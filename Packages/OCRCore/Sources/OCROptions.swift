import Foundation

// MARK: - OCR 识别级别

/// Vision 文本识别的精度级别。
///
/// Vision 的 `.fast` 级别不支持中日韩文字：把 `zh-Hans` 排在首位也只会返回
/// 英文片段。需要识别中日韩时必须使用 `.accurate`。
public enum OCRRecognitionLevel: String, Sendable, CaseIterable {
    /// 高精度识别，支持中日韩文字，速度较慢。
    case accurate
    /// 快速识别，只支持拉丁文字，速度较快。
    case fast
}

// MARK: - OCR 识别选项

/// OCR 识别选项配置
///
/// 提供 OCR 识别的完整配置，包括语言偏好、置信度阈值、布局保留等。
/// 置信度阈值会根据选择的语言自动适配（中文 0.6、英文 0.8、日文 0.65），
/// 也支持手动指定。
///
/// 使用示例:
/// ```swift
/// let options = OCROptions(languages: ["zh-Hans", "en"], preserveLayout: true)
/// let options = OCROptions(minConfidence: 0.75) // 手动覆盖阈值
/// ```
public struct OCROptions: Sendable {
    // MARK: - 配置属性

    /// 语言偏好列表，按优先级排序，默认 `["zh-Hans", "en"]`
    ///
    /// 支持的常见语言标识:
    /// - `zh-Hans` - 简体中文
    /// - `zh-Hant` - 繁体中文
    /// - `en` / `en-US` / `en-GB` - 英语
    /// - `ja` - 日语
    /// - `ko` - 韩语
    /// - `fr` - 法语
    /// - `de` - 德语
    /// - `es` - 西班牙语
    /// - `pt` - 葡萄牙语
    /// - `it` - 意大利语
    public let languages: [String]

    /// 最低置信度阈值（0.0 ~ 1.0）
    ///
    /// 识别结果的整体置信度低于此值时，建议降级处理。
    /// 未指定时根据语言自动选择最严格阈值:
    /// - 中文: `0.6`
    /// - 英文: `0.8`
    /// - 日文: `0.65`
    /// - 默认: `0.7`
    public let minConfidence: Float

    /// 是否保留原始布局
    ///
    /// `true` 时关闭语言校正并检测更小的文本高度，让文本行顺序和位置更贴近原图。
    /// 识别级别由 `recognitionLevel` 决定，默认 `.accurate`。
    public let preserveLayout: Bool

    /// Vision 文本识别的精度级别，默认 `.accurate`
    ///
    /// `.fast` 不支持中日韩文字，只有显式要求速度时才应使用。
    public let recognitionLevel: OCRRecognitionLevel

    /// 是否自动检测文本中的 URL 链接
    ///
    /// `true` 时后处理阶段会对识别结果中的 URL 进行检测和提取。
    public let detectURLs: Bool

    /// 是否启用图像预处理
    ///
    /// `true` 时在识别前进行灰度转换、对比度增强等预处理，
    /// 有助于提高低质量图片的识别率。
    public let imagePreprocessing: Bool

    /// OCR 引擎选择，默认 `.vision`
    ///
    /// 可选引擎:
    /// - `.vision` - Apple Vision 框架（默认，macOS 内置）
    /// - `.tesseract(path)` - Tesseract 引擎（需额外安装语言包）
    /// - `.windowsMediaOcr` - Windows Media OCR（预留）
    public let engineSelection: OCREngineType

    // MARK: - 语言特定阈值

    /// 根据语言返回推荐的置信度阈值
    ///
    /// 阈值来源于设计文档 2.5 节的语言特定置信度要求:
    /// - 中文: 0.6（中文识别准确率相对较低）
    /// - 英文: 0.8（英文识别最可靠）
    /// - 日文: 0.65（日文识别介于中英文之间）
    /// - 其他: 0.7（通用安全阈值）
    ///
    /// - Parameter language: 语言标识符（如 `"zh-Hans"`, `"en"`, `"ja"`）
    /// - Returns: 推荐的最低置信度阈值
    public static func defaultThreshold(for language: String) -> Float {
        switch language {
        case "zh-Hans", "zh-Hant":
            return 0.6
        case "en", "en-US", "en-GB":
            return 0.8
        case "ja":
            return 0.65
        default:
            return 0.7
        }
    }

    // MARK: - 初始化

    /// 创建 OCR 识别选项
    ///
    /// - Parameters:
    ///   - languages: 语言偏好列表，按优先级排序，默认 `["zh-Hans", "en"]`
    ///   - minConfidence: 最低置信度阈值。传 `nil` 时根据语言自动选择最严格阈值。
    ///   - preserveLayout: 是否保留原始布局，默认 `false`
    ///   - recognitionLevel: Vision 识别级别，默认 `.accurate`（支持中日韩）
    ///   - detectURLs: 是否自动检测 URL，默认 `true`
    ///   - imagePreprocessing: 是否启用图像预处理，默认 `true`
    ///   - engineSelection: OCR 引擎选择，默认 `.vision`
    public init(
        languages: [String] = ["zh-Hans", "en"],
        minConfidence: Float? = nil,
        preserveLayout: Bool = false,
        recognitionLevel: OCRRecognitionLevel = .accurate,
        detectURLs: Bool = true,
        imagePreprocessing: Bool = true,
        engineSelection: OCREngineType = .vision
    ) {
        self.languages = languages
        // 如果未指定阈值，取所有语言中阈值最高的作为全局最低要求
        if let minConfidence {
            self.minConfidence = minConfidence
        } else {
            self.minConfidence = languages.map { Self.defaultThreshold(for: $0) }.max() ?? 0.7
        }
        self.preserveLayout = preserveLayout
        self.recognitionLevel = recognitionLevel
        self.detectURLs = detectURLs
        self.imagePreprocessing = imagePreprocessing
        self.engineSelection = engineSelection
    }
}

// MARK: - 便利扩展

extension OCROptions {
    /// 纯英文识别的预设选项
    public static let englishOnly = OCROptions(
        languages: ["en"],
        minConfidence: 0.8
    )

    /// 中文识别预设选项
    public static let chineseOnly = OCROptions(
        languages: ["zh-Hans"],
        minConfidence: 0.6
    )

    /// 布局保留模式的预设选项
    public static let layoutPreserved = OCROptions(
        languages: ["zh-Hans", "en"],
        preserveLayout: true
    )

    /// 快速识别预设选项（优先速度）
    public static let fast = OCROptions(
        languages: ["en"],
        minConfidence: 0.8,
        preserveLayout: false,
        recognitionLevel: .fast,
        imagePreprocessing: false
    )
}
