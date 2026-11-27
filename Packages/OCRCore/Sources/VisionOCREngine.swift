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

    /// 先跑脚本要求的级别，再按策略补齐丢掉的文本行。
    ///
    /// Vision 的 `.accurate` 在「特定内容 × 大画布」组合下会静默丢掉大部分文本行，
    /// 既可能返回 0 条，也可能只返回其中一小部分。丢行的成因是单次请求要覆盖的
    /// 区域太大，所以先用更小的画布把同一引擎重跑一次（`rescueLostLines`），
    /// 结果为空时再用 `.fast` 确认一次。两次补齐都只在同一个引擎内比较文字量；
    /// `.fast` 对中文只会返回乱码，所以跨引擎只按「是否为空」判定，绝不按字符数
    /// 替换，也绝不按置信度筛字。
    private func resolvedLines(
        image: CGImage,
        languages: [String],
        options: OCROptions
    ) async throws -> [OCRLine] {
        let primaryLevel = options.recognitionLevel
        let primary = try await lineRecognizer(image, languages, options, primaryLevel)

        guard primaryLevel == .accurate else {
            return try Self.validated(primary)
        }

        let resolved = try await rescueLostLines(
            primary: primary,
            image: image,
            languages: languages,
            options: options
        )

        guard
            VisionRecognitionPolicy.shouldRetryWithFast(
                lineCount: resolved.count,
                imagePixelCount: image.width * image.height
            )
        else {
            return try Self.validated(resolved)
        }

        try Task.checkCancellation()
        do {
            let fallback = try await lineRecognizer(image, languages, options, .fast)
            if VisionRecognitionPolicy.prefersFastResult(accurate: resolved, fast: fallback) {
                return try Self.validated(fallback)
            }
        } catch {
            // 安全网本身失败时保留「没有文字」的语义：分块路径据此跳过空白块，
            // 一块坏图不该让整张截图失败。`validated` 会抛出可识别的空白错误。
        }
        return try Self.validated(resolved)
    }

    /// 大画布整幅丢行时，用更小的画布把同一引擎重跑一次。
    ///
    /// 触发条件与取舍见 `VisionRecognitionPolicy.shouldRetryAtSmallerScale`。
    /// 补齐是尽力而为：缩图失败或第二次请求报错都保持全幅结果，绝不因为一次
    /// 附加请求丢掉已经可用的识别结果。
    ///
    /// 重跑沿用同一引擎、同一语言列表、同一识别级别，返回的 `boundingBox` 仍是
    /// 归一化坐标，对原图依旧成立（精度按缩放比例下降），调用方无需换算。
    private func rescueLostLines(
        primary: [OCRLine],
        image: CGImage,
        languages: [String],
        options: OCROptions
    ) async throws -> [OCRLine] {
        guard
            VisionRecognitionPolicy.shouldRetryAtSmallerScale(
                characterCount: VisionRecognitionPolicy.nonWhitespaceCharacterCount(primary),
                imageWidth: image.width,
                imageHeight: image.height
            ),
            let scaled = Self.scaled(image, longestSide: VisionRecognitionPolicy.retryLongestSide)
        else {
            return primary
        }

        try Task.checkCancellation()
        do {
            let retry = try await lineRecognizer(scaled, languages, options, .accurate)
            if VisionRecognitionPolicy.prefersSmallerScaleResult(primary: primary, retry: retry) {
                return retry
            }
        } catch {
            // 见上：附加请求失败不改变已经可用的结果。
        }
        return primary
    }

    /// 把整幅图按长边缩到 `longestSide`，供「大画布丢行」的第二次请求使用。
    ///
    /// `MemoryGuard.downsample` 走 `CGImageSource`，只对能编码成图片源的输入有效；
    /// 截图在内存里是裸 `CGImage`，那条路径会返回 `nil`。这里直接用位图上下文
    /// 重绘，并用 `.high` 插值，避免缩小时把小字糊成一片。
    ///
    /// - Parameters:
    ///   - image: 原始图像。
    ///   - longestSide: 目标长边像素数；不比当前更小时返回 `nil`。
    /// - Returns: 缩小后的图像，创建上下文失败时返回 `nil`。
    private static func scaled(_ image: CGImage, longestSide: CGFloat) -> CGImage? {
        let scale = longestSide / CGFloat(max(image.width, image.height))
        guard scale < 1 else { return nil }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
