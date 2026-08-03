import CoreGraphics

/// 屏幕截图坐标转换工具。
///
/// AppKit 使用左下角原点、Y 轴向上的全局点坐标；Quartz 使用左上角原点、
/// Y 轴向下的全局点坐标。转换必须基于选区所在显示器，而不能假设主显示器。
public enum ScreenCoordinateGeometry {
    /// 将 AppKit 全局矩形转换为 Quartz 全局矩形。
    ///
    /// - Parameters:
    ///   - appKitRect: AppKit 全局坐标中的矩形。
    ///   - appKitScreenFrame: 目标显示器的 `NSScreen.frame`。
    ///   - quartzScreenFrame: 同一显示器的 `CGDisplayBounds`。
    /// - Returns: Quartz 全局坐标中的矩形；显示器尺寸无效时返回 `nil`。
    public static func quartzRect(
        from appKitRect: CGRect,
        appKitScreenFrame: CGRect,
        quartzScreenFrame: CGRect
    ) -> CGRect? {
        guard appKitScreenFrame.width > 0, appKitScreenFrame.height > 0,
              quartzScreenFrame.width > 0, quartzScreenFrame.height > 0 else {
            return nil
        }

        let localX = appKitRect.minX - appKitScreenFrame.minX
        let localTop = appKitScreenFrame.maxY - appKitRect.maxY
        return CGRect(
            x: quartzScreenFrame.minX + localX,
            y: quartzScreenFrame.minY + localTop,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }
}
