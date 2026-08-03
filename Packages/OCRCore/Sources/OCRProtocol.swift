import CoreGraphics
import Foundation

// MARK: - OCR 引擎类型

/// OCR 引擎类型
///
/// 标识不同的 OCR 识别引擎，用于引擎选择和结果标记。
/// 当前主要使用 `.vision`（Apple Vision 框架），
/// `.tesseract` 和 `.windowsMediaOcr` 为预留的降级和跨平台选项。
public enum OCREngineType: Sendable, Hashable {
    /// Apple Vision 框架（macOS 内置，零依赖）
    case vision
    /// Tesseract OCR 引擎（需额外安装语言包）
    case tesseract(languageDataPath: URL?)
    /// Windows Media OCR（预留跨平台支持）
    case windowsMediaOcr
}

// MARK: - OCR 协议

/// 跨平台 OCR 协议
///
/// 所有 OCR 引擎需实现此协议以提供统一的识别接口。
/// 使用关联类型 `PlatformImageType` 支持不同平台的图像类型：
/// - macOS: `CGImage`
/// - 未来 Windows: `SoftwareBitmap` 或其他类型
///
/// 实现示例:
/// ```swift
/// final class CustomOCREngine: OCRProtocol {
///     typealias PlatformImageType = CGImage
///     let engineType: OCREngineType = .vision
///     var logHandler: ((OCRLogEntry) -> Void)?
///
///     func recognize(image: CGImage, languages: [String], options: OCROptions) async throws -> OCRResult {
///         // 实现识别逻辑
///     }
///
///     func supportedLanguages() -> [String] {
///         return ["en", "zh-Hans"]
///     }
/// }
/// ```
public protocol OCRProtocol: Sendable {
    /// 平台原生图像类型
    ///
    /// 不同平台使用不同的图像类型:
    /// - macOS: `CGImage`
    /// - Windows (未来): `SoftwareBitmap` 等
    associatedtype PlatformImageType: Sendable

    /// 识别图像中的文本
    /// - Parameters:
    ///   - image: 平台原生图像对象
    ///   - languages: 语言优先级列表，按顺序尝试识别
    ///   - options: 识别选项配置
    /// - Returns: 统一的 OCR 识别结果
    /// - Throws: `OCRError` 当识别失败或引擎不可用时
    func recognize(
        image: PlatformImageType,
        languages: [String],
        options: OCROptions
    ) async throws -> OCRResult

    /// 返回当前引擎支持的所有语言列表
    /// - Returns: 语言标识符数组
    func supportedLanguages() -> [String]

    /// 引擎标识
    var engineType: OCREngineType { get }

    /// 日志回调（用于开发者模式调试和性能分析）
    var logHandler: ((OCRLogEntry) -> Void)? { get set }
}

// MARK: - OCR 错误类型

/// OCR 识别过程的错误类型
///
/// 提供结构化的错误信息，便于调用方根据错误类型做出相应处理。
public enum OCRError: Error, Sendable {
    /// 引擎不可用（如 Tesseract 语言包未安装）
    case engineUnavailable(OCREngineType)
    /// 识别失败（含具体失败原因描述）
    case recognitionFailed(reason: String)
    /// 置信度低于阈值（含实际值和阈值）
    case confidenceTooLow(actual: Float, threshold: Float)
    /// 语言不受当前引擎支持
    case languageNotSupported(String)
    /// 图片尺寸过大无法处理
    case imageTooLarge(width: Int, height: Int)
}

// MARK: - OCRError 便利实现

extension OCRError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .engineUnavailable(let engine):
            return "OCR 引擎不可用: \(engine)"
        case .recognitionFailed(let reason):
            return "OCR 识别失败: \(reason)"
        case .confidenceTooLow(let actual, let threshold):
            return "识别置信度 (\(String(format: "%.2f", actual))) 低于最低要求 (\(String(format: "%.2f", threshold)))"
        case .languageNotSupported(let language):
            return "语言不受支持: \(language)"
        case .imageTooLarge(let width, let height):
            return "图片尺寸过大 (\(width)x\(height))，无法安全分块处理"
        }
    }
}
