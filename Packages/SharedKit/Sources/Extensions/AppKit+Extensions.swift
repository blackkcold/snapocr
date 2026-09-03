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
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }

        let divisor = CGFloat(255)
        let red = CGFloat((number >> (value.count == 8 ? 24 : 16)) & 0xFF) / divisor
        let green = CGFloat((number >> (value.count == 8 ? 16 : 8)) & 0xFF) / divisor
        let blue = CGFloat((number >> (value.count == 8 ? 8 : 0)) & 0xFF) / divisor
        let alpha = value.count == 8 ? CGFloat(number & 0xFF) / divisor : 1
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
