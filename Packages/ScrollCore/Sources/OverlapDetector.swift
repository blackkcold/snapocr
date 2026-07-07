import CoreGraphics
import Foundation

/// 重叠带检测器。
///
/// 使用 SSIM（Structural Similarity Index）算法检测相邻滚动截图帧之间的
/// 重叠区域，并找到最佳拼接偏移位置。
///
/// ## SSIM 算法（设计文档 §2.5 架构完整性补充核查）
/// SSIM 度量两个图像区域的结构相似性，比像素差更适合重叠检测：
/// - 对亮度变化不敏感
/// - 对对比度变化不敏感
/// - 关注结构相似性
///
/// 公式: SSIM(x, y) = [l(x,y)]^α · [c(x,y)]^β · [s(x,y)]^γ
/// 其中 l=亮度比较, c=对比度比较, s=结构比较
/// 默认权重 α=β=γ=1。
///
/// ## 可配置参数
/// - `similarityThreshold`: SSIM 阈值，高于此值认为匹配（默认 0.92）
/// - `searchWindowSize`: 搜索窗口大小（默认 16 像素步进）
/// - `dpiScaleTolerance`: DPI 缩放容忍度（默认 1.05）
public struct OverlapDetector: Sendable {

    /// SSIM 相似度阈值，高于此值判定为匹配。
    /// 设计文档 §2.2 指定为 0.95。
    public let similarityThreshold: Float

    /// 搜索时的步进步长（像素），越小精度越高但越慢
    public let searchStep: Int

    /// SSIM 计算窗口大小（像素）
    public let ssimWindowSize: Int

    /// DPI 缩放因子容忍度
    public let dpiScaleTolerance: CGFloat

    /// 创建重叠检测器。
    ///
    /// - Parameters:
    ///   - similarityThreshold: SSIM 匹配阈值，默认 0.95（设计文档 §2.2）。
    ///   - searchStep: 搜索步长，默认 4 像素。设为 1 获得最高精度。
    ///   - ssimWindowSize: SSIM 窗口大小，默认 8。
    ///   - dpiScaleTolerance: DPI 容忍度，默认 1.05。
    public init(
        similarityThreshold: Float = 0.95,
        searchStep: Int = 4,
        ssimWindowSize: Int = 8,
        dpiScaleTolerance: CGFloat = 1.05
    ) {
        self.similarityThreshold = similarityThreshold
        self.searchStep = max(1, searchStep)
        self.ssimWindowSize = max(4, ssimWindowSize)
        self.dpiScaleTolerance = dpiScaleTolerance
    }

    /// 检测帧序列中相邻帧之间的重叠比例。
    ///
    /// 对帧数组中每对相邻帧 (i, i+1)，计算帧 i 底部与帧 i+1 顶部的重叠像素高度，
    /// 返回以比例为单位的重叠量（0.0 表示无重叠，1.0 表示完全重叠）。
    ///
    /// - Parameter frames: 按捕获顺序排列的帧数组。
    /// - Returns: 相邻帧重叠比例数组，长度为 `frames.count - 1`。
    public func detectOverlaps(_ frames: [ScrollFrame]) -> [CGFloat] {
        guard frames.count >= 2 else { return [] }

        var overlaps: [CGFloat] = []
        overlaps.reserveCapacity(frames.count - 1)

        for i in 0..<(frames.count - 1) {
            let frameA = frames[i]
            let frameB = frames[i + 1]

            let heightA = CGFloat(frameA.image.height)
            let heightB = CGFloat(frameB.image.height)

            let overlapHeight = estimateOverlapHeight(
                frameA: frameA,
                frameB: frameB,
                heightA: heightA,
                heightB: heightB
            )

            let ratio = overlapHeight / heightA
            overlaps.append(min(ratio, 1.0))
        }

        return overlaps
    }

    /// 估算两帧之间的重叠像素高度。
    ///
    /// 结合预估滚动偏移量和实际图像高度，
    /// 通过 SSIM 搜索验证来精确确定重叠范围。
    private func estimateOverlapHeight(
        frameA: ScrollFrame,
        frameB: ScrollFrame,
        heightA: CGFloat,
        heightB: CGFloat
    ) -> CGFloat {
        let scrollOffset = frameA.predictedScrollOffset

        if scrollOffset > 0 && scrollOffset < heightA {
            let estimatedOverlap = heightA - scrollOffset
            let verifiedOffset = findBestMatchOffset(frameA.image, frameB.image)
            if verifiedOffset > 0 {
                return verifiedOffset
            }
            return max(0, estimatedOverlap)
        }

        let matchOffset = findBestMatchOffset(frameA.image, frameB.image)
        if matchOffset > 0 {
            return matchOffset
        }

        return heightA * 0.15
    }

    /// 在相邻帧之间找到最佳拼接偏移量。
    ///
    /// 使用 SSIM 滑动窗口在估算的重叠区域内搜索最佳垂直对齐位置。
    /// 返回 frameB 相对于 frameA 顶部应偏移的像素距离。
    ///
    /// - Parameters:
    ///   - frame1: 前序帧（上方帧）。
    ///   - frame2: 后续帧（下方帧）。
    /// - Returns: frame1 底部应保留的像素高度（即拼接点）。
    public func findBestMatchOffset(
        _ frame1: CGImage,
        _ frame2: CGImage
    ) -> CGFloat {
        let height1 = frame1.height
        let height2 = frame2.height
        let width1 = frame1.width
        let width2 = frame2.width

        let widthRatio = CGFloat(max(width1, width2)) / CGFloat(min(width1, width2))
        if widthRatio > dpiScaleTolerance {
            return 0
        }

        let commonWidth = min(width1, width2)
        let stripHeight = min(height1 / 3, height2 / 3, 400)
        guard stripHeight > ssimWindowSize else { return 0 }

        let searchRange = Int(stripHeight)

        guard
            let pixels1 = grayscalePixels(
                from: frame1,
                region: CGRect(x: 0, y: height1 - searchRange, width: commonWidth, height: searchRange)
            ),
            let pixels2 = grayscalePixels(
                from: frame2,
                region: CGRect(x: 0, y: 0, width: commonWidth, height: searchRange)
            )
        else {
            return 0
        }

        var bestOffset = 0
        var bestSimilarity: Float = 0

        for offset in Swift.stride(from: 0, through: searchRange - ssimWindowSize, by: searchStep) {
            let similarity = computeSSIM(
                pixels1: pixels1,
                pixels2: pixels2,
                offset: offset,
                width: commonWidth,
                height: ssimWindowSize
            )

            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestOffset = offset
            }
        }

        if bestSimilarity < similarityThreshold {
            return 0
        }

        return CGFloat(height1 - searchRange + bestOffset + ssimWindowSize / 2)
    }
}

// MARK: - SSIM Computation

extension OverlapDetector {

    /// 计算两个灰度像素区域之间的 SSIM 值。
    ///
    /// 在指定偏移处取一个 ssimWindowSize 高的窗口，
    /// 分别从两个图像对应的像素带中提取数据，
    /// 计算其结构相似性指数。
    ///
    /// SSIM 公式（简化，α=β=γ=1）:
    /// SSIM(x,y) = (2·μx·μy + C1)·(2·σxy + C2) / ((μx²+μy²+C1)·(σx²+σy²+C2))
    func computeSSIM(
        pixels1: [Float],
        pixels2: [Float],
        offset: Int,
        width: Int,
        height: Int
    ) -> Float {
        let stride = width
        let windowSize = width * height
        var sumX: Float = 0
        var sumY: Float = 0
        var sumXX: Float = 0
        var sumYY: Float = 0
        var sumXY: Float = 0

        let base1 = offset * stride
        for row in 0..<height {
            let rowOffset = row * stride
            for col in 0..<width {
                let idx = rowOffset + col
                let x = pixels1[base1 + idx]
                let y = pixels2[idx]
                sumX += x
                sumY += y
                sumXX += x * x
                sumYY += y * y
                sumXY += x * y
            }
        }

        let n = Float(windowSize)
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
        return numerator / denominator
    }

    /// 从 CGImage 的指定区域提取灰度像素值。
    ///
    /// 将指定矩形区域渲染为灰度位图，返回归一化到 [0, 1] 的浮点像素数组。
    /// 返回 `nil` 表示位图上下文创建失败。
    ///
    /// - Parameters:
    ///   - image: 源图像。
    ///   - region: 要提取的区域（图像坐标系，原点在左上角）。
    /// - Returns: 归一化的灰度像素值数组，按行排列。
    func grayscalePixels(from image: CGImage, region: CGRect) -> [Float]? {
        let width = Int(region.width)
        let height = Int(region.height)
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 1
        let bytesPerRow = width * bytesPerPixel
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

// MARK: - SSIM Constants

extension OverlapDetector {
    static let c1: Float = (0.01 * 255) * (0.01 * 255)
    static let c2: Float = (0.03 * 255) * (0.03 * 255)
}
