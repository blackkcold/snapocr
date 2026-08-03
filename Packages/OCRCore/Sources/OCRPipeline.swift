import CoreGraphics
import Foundation
import SharedKit

// MARK: - OCR 管道编排器

/// OCR 管道编排器
///
/// 负责完整的 OCR 流程编排，按照以下阶段顺序执行:
///
/// ```
/// 输入图像
///   │
///   ├─ 1. 尺寸路由 ── 中等图片全分辨率，超大图片二维分块
///   │
///   ├─ 2. 内存压力检查 ── 超过 200MB 记录警告
///   │
///   ├─ 3. 引擎识别 ── Vision / Tesseract（不可用时回退 Vision）
///   │      │
///   │      └─ 置信度检查 ── 低于阈值记录警告
///   │
///   ├─ 4. 后处理 ── 布局整理、URL 检测等
///   │
///   └─ 5. 输出 ── OCRResult（含文本、置信度、引擎、耗时）
/// ```
///
/// 使用示例:
/// ```swift
/// let pipeline = OCRPipeline()
/// let result = try await pipeline.recognize(image)
/// print(result.text)
/// ```
///
/// 自定义配置:
/// ```swift
/// let options = OCROptions(
///     languages: ["zh-Hans", "en"],
///     preserveLayout: true
/// )
/// let pipeline = OCRPipeline(options: options)
/// ```
public final class OCRPipeline: Sendable {
    // MARK: - 依赖

    private let visionEngine: VisionOCREngine
    private let postProcessor: PostProcessor
    private let options: OCROptions
    private let logger: Logger

    // MARK: - 初始化

    /// 创建 OCR 管道
    /// - Parameter options: OCR 识别选项，默认使用 `OCROptions()`
    public init(options: OCROptions = OCROptions()) {
        self.visionEngine = VisionOCREngine()
        self.postProcessor = PostProcessor()
        self.options = options
        self.logger = Logger(category: "ocr-pipeline")
    }

    // MARK: - 公开方法

    /// 执行完整的 OCR 识别流程
    ///
    /// 流程步骤:
    /// 1. **尺寸路由**: 中等图片保持全分辨率，超大图片自动二维分块
    /// 2. **内存压力检查**: 检查进程常驻内存，超过 200MB 记录警告
    /// 3. **引擎识别**: 根据选项选择引擎执行识别
    /// 4. **置信度检查**: 检查结果置信度是否达到阈值
    /// 5. **后处理**: 布局整理、URL 检测等
    /// 6. **日志记录**: 记录性能指标和处理结果
    ///
    /// - Parameters:
    ///   - image: 输入图像
    ///   - overrideOptions: 单次识别覆盖选项；为 `nil` 时使用初始化选项
    /// - Returns: OCR 识别结果
    /// - Throws: `OCRError` 当识别失败或引擎不可用时
    public func recognize(
        _ image: CGImage,
        options overrideOptions: OCROptions? = nil
    ) async throws -> OCRResult {
        let combinedOptions = overrideOptions ?? options
        logger.info("开始 OCR 识别 | 语言: \(combinedOptions.languages.joined(separator: ", ")) | 引擎: \(engineLabel(combinedOptions.engineSelection))")

        try Task.checkCancellation()

        // 步骤 1: 内存压力监控
        checkMemoryPressure()

        // 步骤 2: 尺寸路由与引擎识别
        let result: OCRResult
        if MemoryGuard.requiresTiling(image) {
            result = try await performTiledRecognition(image: image, options: combinedOptions)
        } else {
            result = try await performRecognition(image: image, options: combinedOptions)
        }

        // 步骤 3: 置信度检查
        evaluateConfidence(result, threshold: combinedOptions.minConfidence)

        // 步骤 4: 后处理
        let processedResult = postProcessor.process(result)

        // 步骤 5: 记录性能指标
        logger.metric("ocr.processing_time", value: processedResult.processingTimeMs, unit: "ms")
        logger.metric("ocr.confidence", value: Double(processedResult.confidence), unit: "score")
        logger.metric("ocr.text_length", value: Double(processedResult.text.count), unit: "chars")

        logger.info("OCR 识别完成 | 耗时: \(String(format: "%.1f", processedResult.processingTimeMs))ms | 置信度: \(String(format: "%.2f", processedResult.confidence)) | 文本长度: \(processedResult.text.count)")

        return processedResult
    }

    /// 检查当前内存压力，超过阈值时记录警告
    private func checkMemoryPressure() {
        guard MemoryGuard.isMemoryPressureHigh() else { return }
        let thresholdMB = Int(MemoryGuard.memoryPressureThreshold / 1024 / 1024)
        logger.warning("内存压力过高 (\(thresholdMB)MB+)，可能影响识别性能")
    }

    // MARK: - 引擎识别

    /// 根据选项选择并执行 OCR 识别
    /// - Parameters:
    ///   - image: 输入图像
    ///   - options: 识别选项
    /// - Returns: OCR 识别结果
    private func performRecognition(image: CGImage, options: OCROptions) async throws -> OCRResult {
        switch options.engineSelection {
        case .vision:
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await visionEngine.recognize(
                image: image,
                languages: options.languages,
                options: options
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.info("Vision 引擎识别 | 耗时: \(String(format: "%.1f", elapsed))ms | 置信度: \(String(format: "%.2f", result.confidence))")
            return result

        case .tesseract(let languageDataPath):
            let tesseractEngine = TesseractOCREngine(languageDataPath: languageDataPath)
            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                let result = try await tesseractEngine.recognize(
                    image: image,
                    languages: options.languages,
                    options: options
                )
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                logger.info("Tesseract 引擎识别 | 耗时: \(String(format: "%.1f", elapsed))ms | 置信度: \(String(format: "%.2f", result.confidence))")
                return result
            } catch {
                logger.warning("Tesseract 不可用，自动降级到 Vision: \(error.localizedDescription)")
                let startTime = CFAbsoluteTimeGetCurrent()
                let result = try await visionEngine.recognize(
                    image: image,
                    languages: options.languages,
                    options: options
                )
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                logger.info("Vision 引擎识别（Tesseract 降级）| 耗时: \(String(format: "%.1f", elapsed))ms | 置信度: \(String(format: "%.2f", result.confidence))")
                return result
            }

        case .windowsMediaOcr:
            throw OCRError.engineUnavailable(.windowsMediaOcr)
        }
    }

    /// 将超大图片拆分为重叠 tile，逐块识别后映射回全图坐标。
    private func performTiledRecognition(image: CGImage, options: OCROptions) async throws -> OCRResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let tiles = TiledOCRProcessor.tiles(imageWidth: image.width, imageHeight: image.height)
        guard !tiles.isEmpty else {
            throw OCRError.imageTooLarge(width: image.width, height: image.height)
        }

        logger.info("超大图片 \(image.width)x\(image.height)，拆分为 \(tiles.count) 个重叠分块")
        let fullSize = CGSize(width: image.width, height: image.height)
        var mappedLines: [OCRLine] = []
        var resultEngine: OCREngineType?

        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            guard let tileImage = image.cropping(to: tile.pixelRect) else {
                throw OCRError.recognitionFailed(reason: "无法裁剪 OCR 分块 \(index + 1)/\(tiles.count)")
            }

            do {
                let tileResult = try await performRecognition(image: tileImage, options: options)
                resultEngine = resultEngine ?? tileResult.engineType
                mappedLines.append(contentsOf: tileResult.observations.map {
                    TiledOCRProcessor.remap($0, from: tile, fullImageSize: fullSize)
                })
            } catch let error as OCRError where isNoTextError(error) {
                logger.debug("OCR 分块 \(index + 1)/\(tiles.count) 未检测到文字")
            }
        }

        try Task.checkCancellation()
        let mergedLines = TiledOCRProcessor.merge(mappedLines)
        guard !mergedLines.isEmpty, let resultEngine else {
            throw OCRError.recognitionFailed(reason: "未识别到任何有效文本")
        }

        let confidence = mergedLines.reduce(Float(0)) { $0 + $1.confidence }
            / Float(mergedLines.count)
        return OCRResult(
            text: mergedLines.map(\.text).joined(separator: "\n"),
            confidence: confidence,
            engineType: resultEngine,
            layoutPreserved: options.preserveLayout,
            observations: mergedLines,
            processingTimeMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    private func isNoTextError(_ error: OCRError) -> Bool {
        guard case .recognitionFailed(let reason) = error else { return false }
        return reason.contains("未识别到任何有效文本")
    }

    // MARK: - 置信度评估

    /// 评估识别结果的置信度，低于阈值时记录警告
    /// - Parameters:
    ///   - result: OCR 识别结果
    ///   - threshold: 最低接受置信度
    private func evaluateConfidence(_ result: OCRResult, threshold: Float) {
        guard result.confidence < threshold else { return }
        logger.warning(
            "识别置信度 (\(String(format: "%.2f", result.confidence))) 低于阈值 (\(String(format: "%.2f", threshold)))"
        )
    }

    // MARK: - 辅助

    /// 获取引擎显示名称
    private func engineLabel(_ engine: OCREngineType) -> String {
        switch engine {
        case .vision: return "Vision"
        case .tesseract: return "Tesseract"
        case .windowsMediaOcr: return "WindowsMediaOCR"
        }
    }
}
