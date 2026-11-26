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

    /// 执行一次 Vision 文本请求。测试可注入假实现，验证回退编排。
    typealias LineRecognizer = (CGImage, [String], OCROptions, OCRRecognitionLevel) async throws -> [OCRLine]

    // MARK: - 协议属性

    let engineType: OCREngineType = .vision

    /// 日志回调。通过 `logHandlerLock` 保护读写，保证 `@unchecked Sendable` 下的线程安全。
    var logHandler: ((OCRLogEntry) -> Void)? {
        get {
            logHandlerLock.lock()
            defer { logHandlerLock.unlock() }
            return _logHandler
        }
        set {
            logHandlerLock.lock()
            defer { logHandlerLock.unlock() }
            _logHandler = newValue
        }
    }

    private var _logHandler: ((OCRLogEntry) -> Void)?
    private let logHandlerLock = NSLock()

    // MARK: - 初始化

    /// 单次 Vision 请求的执行器；测试可注入假实现，验证回退编排。
    private let lineRecognizer: LineRecognizer

    init(lineRecognizer: @escaping LineRecognizer = VisionOCREngine.performVisionRequest) {
        self.lineRecognizer = lineRecognizer
    }

    // MARK: - 识别

    func recognize(
        image: CGImage,
        languages: [String],
        options: OCROptions
    ) async throws -> OCRResult {
        try Task.checkCancellation()
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1–3. 在专用队列上执行 Vision 请求并提取文本行。
        //
        // `VNImageRequestHandler.perform` 是同步阻塞调用。直接放在 async 上下文里
        // 会占住 Swift 并发的协作线程；低核机器上同时打开多个编辑器就能把线程池
        // 耗尽，其余异步任务永远拿不到线程（CI 的 app-tests 正是这样挂住的）。
        let lines = try await resolvedLines(
            image: image,
            languages: languages,
            options: options
        )
        try Task.checkCancellation()

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
        logHandler?(
            OCRLogEntry(
                timestamp: Date(),
                visionConfidence: avgConfidence,
                visionText: result.text,
                visionTimeMs: processingTime
            ))

        return result
    }

    // MARK: - 线程隔离

    /// Vision 请求的执行队列。
    ///
    /// 用并发队列而非串行队列：超大图会切 tile 并发识别，串行队列会把 tile
    /// 重新排成一条队，抵消 `TiledOCRProcessor` 的并发收益。
    private static let recognitionQueue = DispatchQueue(
        label: "app.snapglass.ocr.vision",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// 先跑脚本要求的级别，再按策略决定是否需要 `.fast` 安全网。
    ///
    /// Vision 的 `.accurate` 在「特定内容 × 大画布」组合下会静默返回 0 条，
    /// 这时用 `.fast` 确认一次，避免把「模型没输出」当成「图上没有文字」。
    /// `.fast` 只在找回严格更多文字时才替换 `.accurate`，绝不按置信度筛字。
    private func resolvedLines(
        image: CGImage,
        languages: [String],
        options: OCROptions
    ) async throws -> [OCRLine] {
        let primaryLevel = options.recognitionLevel
        let primary = try await lineRecognizer(image, languages, options, primaryLevel)

        guard
            primaryLevel == .accurate,
            VisionRecognitionPolicy.shouldRetryWithFast(
                lineCount: primary.count,
                imagePixelCount: image.width * image.height
            )
        else {
            return try Self.validated(primary)
        }

        try Task.checkCancellation()
        do {
            let fallback = try await lineRecognizer(image, languages, options, .fast)
            if VisionRecognitionPolicy.prefersFastResult(accurate: primary, fast: fallback) {
                return try Self.validated(fallback)
            }
        } catch {
            // 安全网本身失败时，不能把已经可用的 `.accurate` 结果一起丢掉。
            if primary.isEmpty { throw error }
        }
        return try Self.validated(primary)
    }

    /// 在 `recognitionQueue` 上执行一次 Vision 请求，返回已过滤的文本行。
    ///
    /// 阻塞的 `perform` 留在这个队列上，协作线程池只负责等待，不会被一次 OCR
    /// 长期占用。
    private static func performVisionRequest(
        image: CGImage,
        languages: [String],
        options: OCROptions,
        level: OCRRecognitionLevel
    ) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[OCRLine], Error>) in
            recognitionQueue.async {
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = languages
                request.recognitionLevel = level == .fast ? .fast : .accurate
                request.usesLanguageCorrection = !options.preserveLayout

                // 布局模式下检测更小尺寸的文本
                if options.preserveLayout {
                    request.minimumTextHeight = 0.01
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(
                        throwing: OCRError.recognitionFailed(
                            reason: "Vision 框架识别失败: \(error.localizedDescription)"
                        )
                    )
                    return
                }

                continuation.resume(returning: Self.mapObservations(request.results ?? []))
            }
        }
    }

    /// 把空结果统一成可识别的「没有文字」错误，供分块路径当作空白块处理。
    private static func validated(_ lines: [OCRLine]) throws -> [OCRLine] {
        guard !lines.isEmpty else {
            throw OCRError.recognitionFailed(
                reason: "未识别到任何有效文本（所有候选置信度均低于 0.1）"
            )
        }
        return lines
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

    /// 将 Vision 观察结果映射为 OCRLine，过滤置信度低于 0.1 的候选。
    private static func mapObservations(_ observations: [VNRecognizedTextObservation]) -> [OCRLine] {
        observations.compactMap { observation in
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
    }
}
