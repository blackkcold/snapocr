import CoreGraphics
import Foundation
import Vision

// MARK: - Apple Vision OCR 引擎

/// Apple Vision 框架 OCR 引擎
///
/// 使用 macOS 内置的 Vision 框架进行文本识别，零外部依赖。
/// 支持多语言混合识别、布局保留模式和置信度评分。
///
/// 特性:
/// - 多语言识别（中文、英文、日文、韩文等）
/// - 布局保留模式（使用 `.accurate` 识别级别）
/// - 置信度评分与过滤
/// - 处理耗时统计
/// - 日志回调支持
///
/// 使用示例:
/// ```swift
/// let engine = VisionOCREngine()
/// let result = try await engine.recognize(
///     image: cgImage,
///     languages: ["zh-Hans", "en"],
///     options: OCROptions()
/// )
/// print("识别文本: \(result.text), 置信度: \(result.confidence)")
/// ```
final class VisionOCREngine: OCRProtocol, @unchecked Sendable {
    typealias PlatformImageType = CGImage

    // MARK: - 协议属性

    let engineType: OCREngineType = .vision
    var logHandler: ((OCRLogEntry) -> Void)?

    // MARK: - 初始化

    init() {}

    // MARK: - 识别

    func recognize(
        image: CGImage,
        languages: [String],
        options: OCROptions
    ) async throws -> OCRResult {
        try Task.checkCancellation()
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. 创建并配置文本识别请求
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = languages
        request.recognitionLevel = options.preserveLayout ? .accurate : .fast
        request.usesLanguageCorrection = !options.preserveLayout

        // 布局模式下检测更小尺寸的文本
        if options.preserveLayout {
            request.minimumTextHeight = 0.01
        }

        // 2. 执行识别
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.recognitionFailed(
                reason: "Vision 框架识别失败: \(error.localizedDescription)"
            )
        }
        try Task.checkCancellation()

        guard let observations = request.results else {
            throw OCRError.recognitionFailed(reason: "Vision 未返回识别结果")
        }

        // 3. 提取文本行，过滤过低置信度 (< 0.1) 的观察
        let lines: [OCRLine] = observations.compactMap { observation in
            guard let topCandidate = observation.topCandidates(1).first else {
                return nil
            }
            let confidence = topCandidate.confidence
            guard confidence >= 0.1 else { return nil }

            return OCRLine(
                text: topCandidate.string,
                confidence: confidence,
                boundingBox: observation.boundingBox
            )
        }

        guard !lines.isEmpty else {
            throw OCRError.recognitionFailed(
                reason: "未识别到任何有效文本（所有候选置信度均低于 0.1）"
            )
        }

        // 4. 计算整体平均置信度
        let totalConfidence = lines.reduce(Float(0)) { $0 + $1.confidence }
        let avgConfidence = totalConfidence / Float(max(lines.count, 1))

        // 5. 计算处理耗时（毫秒）
        let processingTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        let result = OCRResult(
            text: lines.map(\.text).joined(separator: "\n"),
            confidence: avgConfidence,
            engineType: .vision,
            layoutPreserved: options.preserveLayout,
            observations: lines,
            processingTimeMs: processingTime
        )

        // 6. 日志回调
        logHandler?(OCRLogEntry(
            timestamp: Date(),
            visionConfidence: avgConfidence,
            visionText: result.text,
            visionTimeMs: processingTime
        ))

        return result
    }

    // MARK: - 支持的语言

    /// 返回 Vision 框架当前支持的识别语言列表
    ///
    /// 此方法动态查询系统 Vision 框架，结果随系统版本和已安装语言模型而变化。
    ///
    /// - Returns: 语言标识符数组（如 `["en-US", "zh-Hans", "ja-JP"]`）
    func supportedLanguages() -> [String] {
        #if !targetEnvironment(macCatalyst)
        // supportedRecognitionLanguages(for:revision:) 在 macOS 12 已弃用但无替代 API
        // macOS 13+ 该调用仍正常工作；仅 .accurate 级别返回完整语言列表
        if let languages = try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate,
            revision: VNRecognizeTextRequestRevision3
        ) {
            return Self.deduplicateLanguages(languages)
        }
        #endif
        // 兜底返回已知支持的常用语言
        return ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"]
    }

    /// 去重短语言代码，优先保留带区域后缀的完整代码（如 en-US 而非 en）
    private static func deduplicateLanguages(_ languages: [String]) -> [String] {
        let unique = languages.reduce(into: [String: String]()) { result, lang in
            let shortCode = String(lang.prefix(2))
            if result[shortCode] == nil || lang.count > (result[shortCode]?.count ?? 0) {
                result[shortCode] = lang
            }
        }
        return unique.values.sorted()
    }
}
