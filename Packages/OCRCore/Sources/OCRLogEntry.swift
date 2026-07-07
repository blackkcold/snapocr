import Foundation

// MARK: - OCR 日志条目

/// OCR 日志条目，用于开发者模式下的引擎对比和性能分析
///
/// 当开发者模式启用时，每次 OCR 请求会同时记录 Vision 和 Tesseract 引擎的
/// 识别结果、置信度和耗时，用于对比分析两个引擎的差异。
///
/// 使用示例:
/// ```swift
/// let entry = OCRLogEntry(
///     timestamp: Date(),
///     visionConfidence: 0.92,
///     tesseractConfidence: 0.88,
///     visionText: "Hello",
///     tesseractText: "Hello",
///     visionTimeMs: 125.3,
///     tesseractTimeMs: 450.1
/// )
/// ```
public struct OCRLogEntry: Sendable, Codable {
    // MARK: - 通用信息

    /// 识别时间戳
    public let timestamp: Date

    // MARK: - Vision 引擎数据

    /// Vision 引擎的识别置信度
    public let visionConfidence: Float

    /// Vision 引擎识别的原始文本
    public let visionText: String

    /// Vision 引擎处理耗时（毫秒）
    public let visionTimeMs: Double

    // MARK: - Tesseract 引擎数据（可选）

    /// Tesseract 引擎的识别置信度，仅开发者模式可用
    public let tesseractConfidence: Float?

    /// Tesseract 引擎识别的原始文本，仅开发者模式可用
    public let tesseractText: String?

    /// Tesseract 引擎处理耗时（毫秒），仅开发者模式可用
    public let tesseractTimeMs: Double?

    // MARK: - 初始化

    /// 创建 OCR 日志条目
    /// - Parameters:
    ///   - timestamp: 识别时间戳
    ///   - visionConfidence: Vision 引擎置信度
    ///   - tesseractConfidence: Tesseract 引擎置信度（可选）
    ///   - visionText: Vision 引擎识别的文本
    ///   - tesseractText: Tesseract 引擎识别的文本（可选）
    ///   - visionTimeMs: Vision 引擎处理耗时（毫秒）
    ///   - tesseractTimeMs: Tesseract 引擎处理耗时（毫秒，可选）
    public init(
        timestamp: Date,
        visionConfidence: Float,
        tesseractConfidence: Float? = nil,
        visionText: String,
        tesseractText: String? = nil,
        visionTimeMs: Double,
        tesseractTimeMs: Double? = nil
    ) {
        self.timestamp = timestamp
        self.visionConfidence = visionConfidence
        self.tesseractConfidence = tesseractConfidence
        self.visionText = visionText
        self.tesseractText = tesseractText
        self.visionTimeMs = visionTimeMs
        self.tesseractTimeMs = tesseractTimeMs
    }
}

// MARK: - 日志条目便利扩展

extension OCRLogEntry {
    /// 两个引擎的置信度差值（Vision - Tesseract）
    /// 正数表示 Vision 更优，负数表示 Tesseract 更优
    public var confidenceDelta: Float? {
        guard let tesseract = tesseractConfidence else { return nil }
        return visionConfidence - tesseract
    }

    /// 耗时差值（Vision - Tesseract），负数表示 Vision 更快
    public var timeDelta: Double? {
        guard tesseractConfidence != nil else { return nil }
        return visionTimeMs - (tesseractTimeMs ?? 0)
    }

    /// 是否两个引擎的识别文本一致
    public var isTextMatch: Bool? {
        guard let tesseractText else { return nil }
        return visionText == tesseractText
    }
}
