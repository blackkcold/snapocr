import CoreGraphics
import Foundation
import ImageIO

/// OCR 内存守卫
///
/// 防止大图片导致内存暴涨。提供图片尺寸预检、高效降采样和内存压力监控。
/// 超过 2048px 宽度的图片自动降采样，超过 200MB 内存压力触发降级。
///
/// 使用示例:
/// ```swift
/// if MemoryGuard.needsDownsample(image) {
///     guard let downsampled = MemoryGuard.downsample(image, targetWidth: 2048) else {
///         throw OCRError.imageTooLarge(width: image.width, height: image.height)
///     }
///     // 使用 downsampled 进行识别
/// }
/// ```
public struct MemoryGuard: Sendable {
    // MARK: - 常量

    /// 最大允许处理的图片宽度（像素）
    ///
    /// 超过此宽度的图片会被自动降采样。
    /// 来源: 设计文档 7.1+ 节，> 4K 分辨率自动降采样至 2048px 宽。
    public static let maxImageWidth: CGFloat = 2048

    /// 内存压力阈值（字节）
    ///
    /// 当前进程常驻内存超过此值时触发降级。
    /// 来源: 设计文档 7.1+ 节，200MB。
    public static let memoryPressureThreshold: UInt64 = 200 * 1024 * 1024 // 200MB

    // MARK: - 图片检查

    /// 检查图片是否需要降采样
    ///
    /// 判断条件: 图片宽度超过 `maxImageWidth`（2048px）
    ///
    /// - Parameter image: 要检查的 CGImage
    /// - Returns: `true` 如果图片需要降采样
    public static func needsDownsample(_ image: CGImage) -> Bool {
        return CGFloat(image.width) > maxImageWidth
    }

    /// 降采样图片到目标宽度
    ///
    /// 使用 `CGImageSource` 进行高效降采样，避免将完整图片解码到内存中。
    /// 保持原始宽高比，且降采样后的图片会被立即缓存。
    ///
    /// - Parameters:
    ///   - image: 原始 CGImage
    ///   - targetWidth: 目标宽度（像素）
    /// - Returns: 降采样后的 CGImage，失败时返回 `nil`
    public static func downsample(_ image: CGImage, targetWidth: CGFloat) -> CGImage? {
        let aspectRatio = CGFloat(image.height) / CGFloat(image.width)
        let targetHeight = targetWidth * aspectRatio

        let options = [kCGImageSourceShouldCache: false] as CFDictionary

        guard let data = image.dataProvider?.data as Data?,
              let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetWidth, targetHeight),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary)
    }

    // MARK: - 内存监控

    /// 检查当前进程内存压力是否超过阈值
    ///
    /// 使用 `task_info` 获取当前进程的常驻内存大小（resident_size），
    /// 与 `memoryPressureThreshold`（200MB）比较。
    ///
    /// - Returns: `true` 如果当前内存使用超过阈值
    public static func isMemoryPressureHigh() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: 1) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    intPtr,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return false }
        return info.resident_size > memoryPressureThreshold
    }
}
