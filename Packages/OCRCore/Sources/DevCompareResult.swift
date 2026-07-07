import Foundation

// MARK: - 引擎对比结果

/// 开发者模式下两个 OCR 引擎的对比结果。
///
/// 包含 Vision 和 Tesseract 两个引擎的识别结果及其对比日志条目。
/// 用于开发者模式（DevMode）下分析两个引擎的精度和性能差异。
///
/// 使用示例:
/// ```swift
/// let result = await DevModeService.shared.compareEngines(
///     image: cgImage,
///     languages: ["zh-Hans", "en"]
/// )
/// if result.isTextMatch {
///     print("两个引擎结果一致 ✓")
/// } else {
///     print("Vision: \(result.vision.text)")
///     print("Tesseract: \(result.tesseract.text)")
/// }
/// ```
public struct DevCompareResult: Sendable {
    // MARK: - 属性

    /// Vision 引擎的识别结果
    public let vision: OCRResult

    /// Tesseract 引擎的识别结果
    public let tesseract: OCRResult

    /// 本次对比的日志条目
    public let log: OCRLogEntry

    // MARK: - 初始化

    /// 创建引擎对比结果。
    ///
    /// - Parameters:
    ///   - vision: Vision 引擎识别结果
    ///   - tesseract: Tesseract 引擎识别结果
    ///   - log: 对比日志条目
    public init(
        vision: OCRResult,
        tesseract: OCRResult,
        log: OCRLogEntry
    ) {
        self.vision = vision
        self.tesseract = tesseract
        self.log = log
    }
}

// MARK: - 对比结果便利扩展

extension DevCompareResult {
    /// 两个引擎的识别文本是否完全一致。
    ///
    /// 忽略引擎差异，直接比较 `text` 属性的字符串值。
    public var isTextMatch: Bool {
        vision.text == tesseract.text
    }

    /// 置信度差值（Vision - Tesseract）。
    ///
    /// - 正数: Vision 引擎置信度更高
    /// - 负数: Tesseract 引擎置信度更高
    /// - 零: 两个引擎置信度相同
    public var confidenceDelta: Float {
        vision.confidence - tesseract.confidence
    }

    /// 耗时差值（Vision - Tesseract），单位毫秒。
    ///
    /// - 负数: Vision 引擎处理速度更快
    /// - 正数: Tesseract 引擎处理速度更快
    /// - 零: 两个引擎耗时相同
    public var timeDelta: Double {
        vision.processingTimeMs - tesseract.processingTimeMs
    }

    /// 较优引擎的名称描述。
    ///
    /// 基于置信度比较，返回置信度更高的引擎名称。
    /// 如果置信度相同，返回 `"两者相当"`。
    public var betterEngine: String {
        if confidenceDelta > 0.01 {
            return "Vision (\(vision.confidence))"
        } else if confidenceDelta < -0.01 {
            return "Tesseract (\(tesseract.confidence))"
        } else {
            return "两者相当"
        }
    }
}
