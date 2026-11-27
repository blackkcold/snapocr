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
    /// 图片里确实没有可识别的文字。
    ///
    /// 与 ``recognitionFailed(reason:)`` 分开，是因为调用方对它的处理完全不同：
    /// 分块路径会把这种情况当作「这一块是空白」跳过，而不是让整张图失败。
    /// 此前这个判断靠在失败文案里找中文短语，于是超时、引擎崩溃这类真正的失败
    /// 只要文案沾上同一句话就会被当成空白吞掉，用户只会看到少了几行字。
    case noTextFound
    /// 单次 Vision 请求超时。
    ///
    /// `perform` 已经超过 ``VisionRequestScheduler/defaultRequestTimeout`` 仍未返回。
    /// 这不是「没有文字」：结果未知，未识别到的部分不能当成空白。
    case visionRequestTimedOut(timeout: Duration)
    /// OCR 引擎已失去响应，无法再接受新请求。
    ///
    /// 所有槽位都被超时的请求占死（Vision 无法中止 `perform`），需要重新启动
    /// 应用才能恢复。这个错误让用户看到明确原因，而不是等到一个永远不来的结果。
    case engineUnresponsive
}

extension OCRError {
    /// 这次失败是否表示「图中没有文字」。
    ///
    /// 只有 ``noTextFound`` 为真。超时、引擎崩溃、语言不支持都不算：把它们当成
    /// 空白会让分块路径静默跳过一整块内容。
    ///
    /// 历史上这里用失败文案匹配中文短语，任何复用了同一句话的错误都会被误判；
    /// 现在判据是错误本身的结构。
    public var isNoText: Bool {
        if case .noTextFound = self { return true }
        return false
    }

    /// 是否属于下游可以立刻放弃、不必重试的引擎状态。
    ///
    /// ``engineUnresponsive`` 表示线程池已经耗尽，继续发请求只会排队到期；
    /// 调用方应当直接把失败报给用户。
    public var isEngineUnresponsive: Bool {
        if case .engineUnresponsive = self { return true }
        return false
    }
}

// MARK: - OCRError 便利实现

extension OCRError: LocalizedError {
    /// A user-facing description of the failure, including the engine, size, or
    /// threshold involved when the case carries one.
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
        case .noTextFound:
            return "未识别到文字"
        case .visionRequestTimedOut(let timeout):
            let seconds =
                Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            return "文字识别超时（超过 \(Int(seconds.rounded())) 秒未返回）"
        case .engineUnresponsive:
            return "文字识别引擎已无响应，请重新启动 SnapGlass 后重试"
        }
    }
}
