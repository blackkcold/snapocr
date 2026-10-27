import AppKit
import SharedKit

/// 统一的图片剪贴板写入。
///
/// 0.9.0 只把渲染搬到后台，`NSPasteboard.writeObjects([NSImage])` 的 TIFF
/// 序列化仍在主线程，5K 截图一次可阻塞 50–150ms。这里改为后台编码 PNG、
/// 主线程只写 `Data`，四条复制路径共用同一条实现。
enum ClipboardWriter {
    static func write(image: CGImage) async throws {
        let data = try await Task.detached(priority: .userInitiated) {
            try ImageEncoder.encode(image, format: .png)
        }.value
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }
}
