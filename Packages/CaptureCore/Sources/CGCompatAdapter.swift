import AppKit
import CoreGraphics
import Foundation
import SharedKit

// MARK: - CGCompatAdapter

/// Core Graphics 兼容截图适配器。
///
/// 使用传统的 Core Graphics API 实现截图功能，作为 ScreenCaptureKit 的降级方案。
/// 适用于 macOS 13-14 系统，以及 SCK 不可用或捕获失败时的备选路径。
///
/// ## 特性
/// - `CGDisplayCreateImage` — 全屏截图
/// - `CGWindowListCreateImage` — 窗口截图和区域截图
/// - `CGWindowListCopyWindowInfo` — 窗口枚举
/// - 多显示器 DPI 差异检测（基于 `NSScreen`）
/// - Retina 高分辨率支持（`.optionHighResolution`）
///
/// ## 设计说明
/// 根据设计文档 Section 2.2（多显示器 DPI 差异处理），
/// 本适配器通过 `NSScreen.backingScaleFactor` 检测各显示器的缩放因子，
/// 并在截图时使用对应的分辨率，确保跨显示器场景下截图质量一致。
final class CGCompatAdapter: @unchecked Sendable {
    private let logger: Logger

    init(logger: Logger = Logger(category: "cg-compat")) {
        self.logger = logger
    }

    // MARK: - Fullscreen Capture

    /// 捕获指定显示器的全屏图像。
    ///
    /// - Parameter displayID: 目标显示器的 `CGDirectDisplayID`。
    /// - Returns: 全屏截图 `CGImage`，失败时返回 `nil`。
    func captureDisplay(_ displayID: CGDirectDisplayID) -> CGImage? {
        logger.debug("Capturing display \(displayID) via CGDisplayCreateImage")

        guard let image = CGDisplayCreateImage(displayID) else {
            logger.error("CGDisplayCreateImage failed for display \(displayID)")
            return nil
        }

        return image
    }

    /// 捕获指定显示器的全屏图像，包含 DPI 感知。
    ///
    /// 根据显示器的实际缩放因子调整输出分辨率。
    ///
    /// - Parameters:
    ///   - displayID: 目标显示器的 `CGDirectDisplayID`。
    ///   - highResolution: 是否使用高分辨率（Retina 数据）。
    /// - Returns: 全屏截图 `CGImage`，失败时返回 `nil`。
    func captureDisplay(_ displayID: CGDirectDisplayID, highResolution: Bool) -> CGImage? {
        guard let baseImage = CGDisplayCreateImage(displayID) else {
            return nil
        }

        guard !highResolution else {
            return baseImage
        }

        let bounds = CGDisplayBounds(displayID)
        return Self.resize(
            baseImage,
            width: max(1, Int(bounds.width.rounded(.up))),
            height: max(1, Int(bounds.height.rounded(.up)))
        )
    }

    // MARK: - Window Capture

    /// 捕获指定窗口的图像。
    ///
    /// 使用 `CGWindowListCreateImage` 捕获目标窗口的可见内容。
    /// 支持高分辨率模式，通过 `.optionHighResolution` 标志启用。
    ///
    /// - Parameter windowID: 目标窗口的 `CGWindowID`。
    /// - Returns: 窗口截图 `CGImage`，失败时返回 `nil`。
    func captureWindow(_ windowID: CGWindowID, highResolution: Bool = true) -> CGImage? {
        logger.debug("Capturing window \(windowID) via CGWindowListCreateImage")

        guard let windowInfo = windowInfo(for: windowID) else {
            logger.warning("Window \(windowID) not found")
            return nil
        }

        let bounds = windowInfo.bounds
        let image = CGWindowListCreateImage(
            bounds,
            .optionIncludingWindow,
            windowID,
            highResolution ? [.bestResolution] : [.nominalResolution]
        )

        guard let result = image else {
            logger.error("CGWindowListCreateImage returned nil for window \(windowID)")
            return nil
        }

        return result
    }

    /// 捕获指定区域的屏幕图像。
    ///
    /// - Parameters:
    ///   - rect: 截图区域（屏幕坐标）。
    ///   - displayID: 区域所在显示器的标识符。
    /// - Returns: 区域截图 `CGImage`，失败时返回 `nil`。
    func captureRect(
        _ rect: CGRect,
        displayID: CGDirectDisplayID,
        highResolution: Bool = true
    ) -> CGImage? {
        logger.debug("Capturing rect \(rect) on display \(displayID)")

        guard let image = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            highResolution ? [.bestResolution] : [.nominalResolution]
        ) else {
            logger.error("CGWindowListCreateImage (rect) returned nil")
            return nil
        }

        return image
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Window Enumeration

    /// 枚举当前屏幕上所有可见窗口。
    ///
    /// - Returns: 窗口信息字典数组，每个字典包含 `kCGWindowNumber`、`kCGWindowBounds` 等键。
    func enumerateWindows() -> [[String: Any]] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            logger.warning("CGWindowListCopyWindowInfo returned nil")
            return []
        }

        logger.debug("Enumerated \(windowList.count) windows")
        return windowList
    }

    // MARK: - Display Helpers

    /// 获取指定显示器的缩放因子（DPI）。
    ///
    /// 通过 `NSScreen` 的后备缩放因子检测显示器的实际 DPI。
    /// 用于多显示器场景下的 DPI 差异处理（设计文档 Section 2.2）。
    ///
    /// - Parameter displayID: 显示器的 `CGDirectDisplayID`。
    /// - Returns: 缩放因子（2.0 为 Retina，1.0 为标准分辨率）。
    func backingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let screens = NSScreen.screens
        for screen in screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
               screenNumber == displayID {
                return screen.backingScaleFactor
            }
        }
        return 1.0
    }

    /// 获取包含给定点的最佳显示器标识符。
    ///
    /// - Parameter point: 屏幕坐标中的点。
    /// - Returns: 包含该点的显示器 `CGDirectDisplayID`，未找到时返回主显示器 ID。
    func displayID(for point: CGPoint) -> CGDirectDisplayID {
        let maxDisplays: UInt32 = 32
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        guard CGGetActiveDisplayList(maxDisplays, &displayIDs, &displayCount) == .success else {
            return CGMainDisplayID()
        }

        for i in 0 ..< Int(displayCount) {
            let bounds = CGDisplayBounds(displayIDs[i])
            if bounds.contains(point) {
                return displayIDs[i]
            }
        }

        return CGMainDisplayID()
    }

    /// 获取指定显示器的帧。
    ///
    /// - Parameter displayID: 显示器的 `CGDirectDisplayID`。
    /// - Returns: 显示器在全局坐标系中的帧。
    func frame(for displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    /// 检查显示器是否处于活动状态。
    ///
    /// - Parameter displayID: 显示器的 `CGDirectDisplayID`。
    /// - Returns: 显示器是否在线且可用。
    func isDisplayActive(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(displayID) != 0
    }
}

// MARK: - Window Info

/// 简化的窗口信息结构
private struct WindowInfo {
    let windowID: CGWindowID
    let bounds: CGRect
    let name: String?
}

/// 从窗口信息字典中提取窗口信息
private extension CGCompatAdapter {
    func windowInfo(for windowID: CGWindowID) -> WindowInfo? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for entry in windowList {
            guard let entryID = entry[kCGWindowNumber as String] as? UInt32,
                  entryID == windowID else {
                continue
            }

            let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat]
            let bounds = CGRect(
                x: boundsDict?["X"] ?? 0,
                y: boundsDict?["Y"] ?? 0,
                width: boundsDict?["Width"] ?? 0,
                height: boundsDict?["Height"] ?? 0
            )
            let name = entry[kCGWindowName as String] as? String

            return WindowInfo(windowID: windowID, bounds: bounds, name: name)
        }

        return nil
    }
}
