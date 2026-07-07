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
///   ├─ 1. 内存守卫 ── 超过 2048px 自动降采样
///   │
///   ├─ 2. 内存压力检查 ── 超过 200MB 记录警告
///   │
///   ├─ 3. 引擎识别 ── Vision（当前）/ Tesseract（预留）
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
    /// 1. **内存守卫**: 检查图片尺寸，超过 2048px 自动降采样
    /// 2. **内存压力检查**: 检查进程常驻内存，超过 200MB 记录警告
    /// 3. **引擎识别**: 根据选项选择引擎执行识别
    /// 4. **置信度检查**: 检查结果置信度是否达到阈值
    /// 5. **后处理**: 布局整理、URL 检测等
    /// 6. **日志记录**: 记录性能指标和处理结果
    ///
    /// - Parameter image: 输入图像
    /// - Returns: OCR 识别结果
    /// - Throws: `OCRError` 当识别失败或引擎不可用时
    public func recognize(_ image: CGImage) async throws -> OCRResult {
        let combinedOptions = options
        logger.info("开始 OCR 识别 | 语言: \(combinedOptions.languages.joined(separator: ", ")) | 引擎: \(engineLabel(combinedOptions.engineSelection))")

        // 步骤 1: 内存守卫 - 大图降采样
        let processedImage = try await performMemoryGuard(image)

        // 步骤 2: 内存压力监控
        checkMemoryPressure()

        // 步骤 3: 引擎识别
        let result = try await performRecognition(image: processedImage, options: combinedOptions)

        // 步骤 4: 置信度检查
        evaluateConfidence(result, threshold: combinedOptions.minConfidence)

        // 步骤 5: 后处理
        let processedResult = postProcessor.process(result)

        // 步骤 6: 记录性能指标
        logger.metric("ocr.processing_time", value: processedResult.processingTimeMs, unit: "ms")
        logger.metric("ocr.confidence", value: Double(processedResult.confidence), unit: "score")
        logger.metric("ocr.text_length", value: Double(processedResult.text.count), unit: "chars")

        logger.info("OCR 识别完成 | 耗时: \(String(format: "%.1f", processedResult.processingTimeMs))ms | 置信度: \(String(format: "%.2f", processedResult.confidence)) | 文本长度: \(processedResult.text.count)")

        return processedResult
    }

    // MARK: - 内存守卫

    /// 执行内存守卫检查，必要时降采样图片
    /// - Parameter image: 输入图像
    /// - Returns: 处理后的图像（可能已降采样）
    private func performMemoryGuard(_ image: CGImage) async throws -> CGImage {
        guard MemoryGuard.needsDownsample(image) else {
            return image
        }

        let imageInfo = "\(image.width)x\(image.height)"
        logger.info("图片尺寸过大 (\(imageInfo))，执行降采样至 \(Int(MemoryGuard.maxImageWidth))px")

        guard let downsampled = MemoryGuard.downsample(image, targetWidth: MemoryGuard.maxImageWidth) else {
            throw OCRError.imageTooLarge(width: image.width, height: image.height)
        }

        logger.info("降采样完成: \(imageInfo) → \(downsampled.width)x\(downsampled.height)")
        return downsampled
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

        case .tesseract:
            // Tesseract 引擎尚未实现，降级到 Vision
            logger.warning("Tesseract 引擎尚未实现，自动降级到 Vision 引擎")
            let startTime = CFAbsoluteTimeGetCurrent()
            let result = try await visionEngine.recognize(
                image: image,
                languages: options.languages,
                options: options
            )
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.info("Vision 引擎识别（Tesseract 降级）| 耗时: \(String(format: "%.1f", elapsed))ms | 置信度: \(String(format: "%.2f", result.confidence))")
            return result

        case .windowsMediaOcr:
            throw OCRError.engineUnavailable(.windowsMediaOcr)
        }
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
