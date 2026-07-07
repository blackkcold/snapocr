import AppKit
import Foundation

// MARK: - AppKit 扩展
// 共享的 AppKit 类型扩展

extension NSImage {

    /// 转换为 CGImage
    /// - Returns: 转换后的 CGImage，失败返回 nil
    public var cgImage: CGImage? {
        guard let data = tiffRepresentation,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

extension NSColor {

    /// 通过十六进制颜色字符串创建 NSColor
    /// - Parameter hex: 十六进制颜色字符串，如 "#FF5733"
    public convenience init?(hex: String) {
        // TODO: 实现十六进制颜色解析
        self.init(white: 0.5, alpha: 1.0)
    }
}
