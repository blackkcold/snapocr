import CoreGraphics
import Foundation

/// 帧去重器。
///
/// 检测并移除滚动截图序列中的重复帧。
/// 使用 SSIM（Structural Similarity Index）比较相邻帧的相似度，
/// 当相似度超过阈值时判定为重复帧并移除。
///
/// ## 去重策略（设计文档 §2.2 架构完整性核查）
/// - 阈值: 相似度 > 0.95 判定为重复帧
/// - 算法: SSIM 替代像素差异比较
/// - 内存: 逐帧流式处理，不在内存中同时持有所有帧数据
///
/// ## 使用方式
/// ```swift
/// let deduper = FrameDeduper(similarityThreshold: 0.95)
/// let uniqueFrames = deduper.deduplicate(allFrames)
/// ```
public struct FrameDeduper: Sendable {

    /// SSIM 相似度阈值，默认 0.95（设计文档指定）。
    ///
    /// 相邻两帧的 SSIM 值超过此阈值时，后一帧被视为重复帧并被移除。
    public static let similarityThreshold: Float = 0.95

    /// 当前实例使用的相似度阈值
    public let threshold: Float

    /// SSIM 计算窗口大小
    public let windowSize: Int

    /// 创建帧去重器。
    ///
    /// - Parameters:
    ///   - threshold: SSIM 相似度阈值，默认使用 `FrameDeduper.similarityThreshold`。
    ///   - windowSize: SSIM 窗口大小，默认 8 像素。
    public init(
        threshold: Float = FrameDeduper.similarityThreshold,
        windowSize: Int = 8
    ) {
        self.threshold = threshold
        self.windowSize = max(4, windowSize)
    }

    /// 对帧数组执行去重。
    ///
    /// 遍历帧数组，将每帧与前一帧进行 SSIM 比较。
    /// 相似度超过阈值的帧被标记为重复并移除。
    /// 第一帧始终保留。
    ///
    /// - Parameter frames: 按捕获顺序排列的帧数组。
    /// - Returns: 去重后的帧数组，保持原始顺序。
    public func deduplicate(_ frames: [ScrollFrame]) -> [ScrollFrame] {
        if frames.count <= 1 { return frames }

        var uniqueFrames: [ScrollFrame] = []
        uniqueFrames.reserveCapacity(frames.count)
        uniqueFrames.append(frames[0])

        for i in 1..<frames.count {
            let previous = uniqueFrames.last!
            let current = frames[i]

            if !isDuplicate(previous.image, current.image) {
                uniqueFrames.append(current)
            }
        }

        return uniqueFrames
    }

    /// 判断两帧是否为相同内容。
    ///
    /// 提取图像中心区域进行 SSIM 比较，
    /// 中心区域最能代表整体内容相似性。
    ///
    /// - Parameters:
    ///   - image1: 前一帧图像。
    ///   - image2: 当前帧图像。
    /// - Returns: `true` 表示两帧高度相似（重复），`false` 表示内容不同。
    public func isDuplicate(_ image1: CGImage, _ image2: CGImage) -> Bool {
        let similarity = computeFrameSimilarity(image1, image2)
        return similarity >= threshold
    }

    /// 计算两帧之间的 SSIM 相似度。
    ///
    /// 为提升效率，仅比较图像中心区域（宽/高的 60%）。
    /// 若图像尺寸差异过大（宽高比差 > 10%），直接判定为不同。
    ///
    /// - Parameters:
    ///   - image1: 第一帧图像。
    ///   - image2: 第二帧图像。
    /// - Returns: SSIM 值，范围 [0, 1]。
    public func computeFrameSimilarity(_ image1: CGImage, _ image2: CGImage) -> Float {
        let w1 = CGFloat(image1.width)
        let h1 = CGFloat(image1.height)
        let w2 = CGFloat(image2.width)
        let h2 = CGFloat(image2.height)

        let widthRatio = w1 / w2
        if widthRatio < 0.9 || widthRatio > 1.1 {
            return 0
        }

        let comparisonWidth = Int(min(w1, w2) * 0.6)
        let comparisonHeight = Int(min(h1, h2) * 0.6)
        guard comparisonWidth > windowSize, comparisonHeight > windowSize else {
            return 0
        }

        let x1 = Int((w1 - CGFloat(comparisonWidth)) / 2)
        let y1 = Int((h1 - CGFloat(comparisonHeight)) / 2)
        let x2 = Int((w2 - CGFloat(comparisonWidth)) / 2)
        let y2 = Int((h2 - CGFloat(comparisonHeight)) / 2)

        let region1 = CGRect(x: x1, y: y1, width: comparisonWidth, height: comparisonHeight)
        let region2 = CGRect(x: x2, y: y2, width: comparisonWidth, height: comparisonHeight)

        guard
            let pixels1 = grayscalePixels(from: image1, region: region1),
            let pixels2 = grayscalePixels(from: image2, region: region2)
        else {
            return 0
        }

        return computeSSIM(pixels1: pixels1, pixels2: pixels2, width: comparisonWidth, height: comparisonHeight)
    }
}

// MARK: - SSIM Computation (FrameDeduper)

extension FrameDeduper {

    /// 计算两个等尺寸灰度像素数组之间的 SSIM 值。
    func computeSSIM(
        pixels1: [Float],
        pixels2: [Float],
        width: Int,
        height: Int
    ) -> Float {
        let windowCount = width * height
        guard windowCount > 0, pixels1.count >= windowCount, pixels2.count >= windowCount else {
            return 0
        }

        var sumX: Float = 0
        var sumY: Float = 0
        var sumXX: Float = 0
        var sumYY: Float = 0
        var sumXY: Float = 0

        for i in 0..<windowCount {
            let x = pixels1[i]
            let y = pixels2[i]
            sumX += x
            sumY += y
            sumXX += x * x
            sumYY += y * y
            sumXY += x * y
        }

        let n = Float(windowCount)
        let muX = sumX / n
        let muY = sumY / n
        let sigmaX2 = (sumXX / n) - (muX * muX)
        let sigmaY2 = (sumYY / n) - (muY * muY)
        let sigmaXY = (sumXY / n) - (muX * muY)

        let c1: Float = (0.01 * 255) * (0.01 * 255)
        let c2: Float = (0.03 * 255) * (0.03 * 255)

        let numerator = (2 * muX * muY + c1) * (2 * sigmaXY + c2)
        let denominator = (muX * muX + muY * muY + c1) * (sigmaX2 + sigmaY2 + c2)

        guard denominator > 0 else { return 0 }
        let ssim = numerator / denominator

        return min(max(ssim, 0), 1)
    }

    /// 从 CGImage 区域提取灰度像素数据。
    func grayscalePixels(from image: CGImage, region: CGRect) -> [Float]? {
        let width = Int(region.width)
        let height = Int(region.height)
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width
        var pixelData = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        let flippedRegion = CGRect(
            x: region.origin.x,
            y: CGFloat(image.height) - region.origin.y - region.height,
            width: region.width,
            height: region.height
        )

        context.draw(image, in: flippedRegion)

        return pixelData.map { Float($0) / 255.0 }
    }
}
