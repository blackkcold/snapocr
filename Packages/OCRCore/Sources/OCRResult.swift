import CoreGraphics
import Foundation

// MARK: - OCR 识别单行文本

/// OCR 识别结果中的单行文本
///
/// 表示图像中识别出的一个文本行，包含文本内容、置信度和位置信息。
/// `boundingBox` 使用归一化坐标（0.0 ~ 1.0），原点在左下角，
/// 与 Vision 框架的坐标系统一致。
///
/// 使用示例:
/// ```swift
/// let line = OCRLine(
///     text: "Hello, World!",
///     confidence: 0.95,
///     boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.05)
/// )
/// ```
public struct OCRLine: Sendable {
    /// 识别的文本内容
    public let text: String

    /// 置信度（0.0 ~ 1.0），越高表示识别结果越可靠
    public let confidence: Float

    /// 文本行在原始图像中的归一化边界框
    ///
    /// 坐标系统:
    /// - `x`, `y`: 左下角原点，取值范围 0.0 ~ 1.0
    /// - `width`, `height`: 相对图像尺寸的比例，取值范围 0.0 ~ 1.0
    /// - 原点为图像左下角，y 轴向上
    public let boundingBox: CGRect

    /// 创建文本行
    /// - Parameters:
    ///   - text: 识别的文本内容
    ///   - confidence: 置信度（0.0 ~ 1.0）
    ///   - boundingBox: 归一化边界框
    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

// MARK: - OCR 识别结果

/// OCR 识别结果
///
/// 包含从图像中识别出的所有文本信息，以及引擎、置信度等元数据。
/// 该类型跨平台通用，不依赖任何平台特定框架。
///
/// 使用示例:
/// ```swift
/// let result = OCRResult(
///     text: "Hello\nWorld",
///     confidence: 0.92,
///     engineType: .vision,
///     layoutPreserved: false,
///     observations: [line1, line2],
///     processingTimeMs: 245.3
/// )
/// print("识别文本: \\(result.text)")
/// print("置信度: \\(result.confidence)")
/// ```
public struct OCRResult: Sendable {
    /// 完整识别的文本内容，每行以 `\n` 分隔
    ///
    /// 等同于 `observations.map(\\.text).joined(separator: "\\n")`
    public let text: String

    /// 整体平均置信度
    ///
    /// 为所有 `observations` 中置信度的算术平均值。
    /// 取值范围 0.0 ~ 1.0。
    public let confidence: Float

    /// 使用的 OCR 引擎类型
    public let engineType: OCREngineType

    /// 是否保留了原始文本布局
    ///
    /// `true` 表示识别时使用了 `.accurate` 级别以保留布局，
    /// 文本行顺序和位置尽可能贴近原始图像。
    public let layoutPreserved: Bool

    /// 所有识别的文本行
    ///
    /// 每个元素对应图像中的一个文本行，按识别顺序排列。
    public let observations: [OCRLine]

    /// 处理耗时（毫秒）
    ///
    /// 从调用引擎识别到返回结果的完整耗时。
    public let processingTimeMs: Double

    /// 创建 OCR 识别结果
    /// - Parameters:
    ///   - text: 完整识别的文本内容
    ///   - confidence: 整体平均置信度
    ///   - engineType: 使用的 OCR 引擎
    ///   - layoutPreserved: 是否保留了布局
    ///   - observations: 所有识别的文本行
    ///   - processingTimeMs: 处理耗时（毫秒）
    public init(
        text: String,
        confidence: Float,
        engineType: OCREngineType,
        layoutPreserved: Bool,
        observations: [OCRLine],
        processingTimeMs: Double
    ) {
        self.text = text
        self.confidence = confidence
        self.engineType = engineType
        self.layoutPreserved = layoutPreserved
        self.observations = observations
        self.processingTimeMs = processingTimeMs
    }
}

// MARK: - OCRResult 便利扩展

extension OCRResult {
    /// 是否达到最低置信度要求
    /// - Parameter threshold: 置信度阈值
    /// - Returns: `true` 如果整体置信度 >= 阈值
    public func meetsConfidenceThreshold(_ threshold: Float) -> Bool {
        return confidence >= threshold
    }

    /// 返回置信度高于指定阈值的文本行
    /// - Parameter threshold: 置信度阈值
    /// - Returns: 过滤后的文本行数组
    public func lines(above threshold: Float) -> [OCRLine] {
        return observations.filter { $0.confidence >= threshold }
    }

    /// 返回置信度高于指定阈值的文本
    /// - Parameter threshold: 置信度阈值
    /// - Returns: 过滤后的完整文本
    public func text(above threshold: Float) -> String {
        return lines(above: threshold).map(\.text).joined(separator: "\n")
    }
}
