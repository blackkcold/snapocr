import CoreGraphics

/// 把一次区域截图选区映射成预截原图里的像素裁剪矩形。
///
/// 选区矩形必须使用 Quartz 全局坐标（原点在左上、Y 轴向下），与
/// `CGImage.cropping(to:)` 的约定一致；`displayFrame` 用 `CGDisplayBounds`，
/// `imageSize` 用预截原图的像素尺寸。副屏在主屏上方、左右两侧、以及
/// Retina 与 1x 混合缩放都由本方法处理，不做任何假设。
///
/// 屏幕边缘的选区常常带着浮点溢出（例如 `1920.0000001`），严格 `contains`
/// 会直接判定跨屏失败，因此允许 `containmentTolerance` 点以内的溢出，先在
/// 显示器范围内夹取再取整；真正的跨屏选区（超出容差）仍然返回 `nil`。
public enum RegionPixelMapping {
    /// 选区允许越过显示器边界的容差（点）。
    public static let containmentTolerance: CGFloat = 1

    /// 计算选区在预截原图中的像素裁剪矩形。
    ///
    /// - Parameters:
    ///   - areaRect: Quartz 全局坐标下的选区（顶部原点）。
    ///   - displayFrame: 该显示器的 Quartz 边界（`CGDisplayBounds`）。
    ///   - imageSize: 预截原图的像素尺寸。
    /// - Returns: 落在图像范围内、已取整的裁剪矩形；跨屏或无效时返回 `nil`。
    public static func pixelCropRect(
        areaRect: CGRect,
        displayFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0,
              displayFrame.width > 0, displayFrame.height > 0
        else { return nil }

        let area = areaRect.standardized
        guard area.width > 0, area.height > 0 else { return nil }

        let tolerantFrame = displayFrame.insetBy(
            dx: -containmentTolerance,
            dy: -containmentTolerance
        )
        guard tolerantFrame.contains(area) else { return nil }

        let clamped = area.intersection(displayFrame)
        guard !clamped.isEmpty else { return nil }

        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let cropRect = CGRect(
            x: (clamped.minX - displayFrame.minX) * scaleX,
            y: (clamped.minY - displayFrame.minY) * scaleY,
            width: clamped.width * scaleX,
            height: clamped.height * scaleY
        ).integral

        let clampedToImage = cropRect.intersection(CGRect(origin: .zero, size: imageSize))
        return clampedToImage.isEmpty ? nil : clampedToImage
    }
}
