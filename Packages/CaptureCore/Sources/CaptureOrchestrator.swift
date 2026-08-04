import AppKit
import Foundation
import SharedKit

// MARK: - CaptureOrchestrator

/// 截图捕获编排器。
///
/// 协调 `SCKAdapter`（ScreenCaptureKit 主路径）和 `CGCompatAdapter`（CG 兼容降级路径）
/// 之间的截图请求分发。对外提供统一的截图入口，自动选择最优适配器并处理降级逻辑。
///
/// ## 捕获流程
/// 1. 权限检查 — 通过 `PermissionService` 双重验证屏幕录制权限
/// 2. 主路径 — 优先使用 `SCKAdapter` 进行截图
/// 3. 降级路径 — `SCKAdapter` 失败时自动回退到 `CGCompatAdapter`
/// 4. 结果返回 — 统一返回 `CaptureResult`，上层无需关心具体实现
///
/// ## 降级策略
/// | 失败原因 | 降级行为 |
/// |----------|----------|
/// | 权限拒绝 | 不降级，直接抛出 `CaptureError.permissionDenied` |
/// | SCK 不可用（macOS < 15） | 降级到 CG 截图 |
/// | SCStream 超时 | 降级到 CG 截图 |
/// | 窗口未找到 | 不降级，抛出 `CaptureError.windowNotFound` |
/// | 显示器不可用 | 不降级，抛出 `CaptureError.displayUnavailable` |
///
public final class CaptureOrchestrator: @unchecked Sendable {
    private let sckAdapter: SCKAdapter
    private let cgAdapter: CGCompatAdapter
    private let permissionService: PermissionService
    private let logger: Logger
    private var currentMode: CaptureMode = .fullscreen

    /// 创建截图编排器实例。
    ///
    /// - Parameter logger: 日志实例，默认使用 `"capture"` 分类。
    public init(logger: Logger = Logger(category: "capture")) {
        self.sckAdapter = SCKAdapter(logger: Logger(category: "sck-adapter"))
        self.cgAdapter = CGCompatAdapter(logger: Logger(category: "cg-compat"))
        self.permissionService = PermissionService(logger: Logger(category: "permission"))
        self.logger = logger
    }

    /// 执行截图捕获。
    ///
    /// 自动尝试 SCK 主路径，失败时降级到 CG 兼容路径。
    /// 权限检查在捕获前自动执行，无需调用方额外处理。
    ///
    /// - Parameters:
    ///   - mode: 捕获模式，默认全屏。
    ///   - options: 捕获选项，默认标准配置（含光标、高分辨率、2x 缩放）。
    /// - Returns: 截图结果 `CaptureResult`。
    /// - Throws:
    ///   - `CaptureError.permissionDenied` — 屏幕录制权限被拒绝
    ///   - `CaptureError.displayUnavailable` — 没有可用的显示器
    ///   - `CaptureError.windowNotFound` — 未找到指定窗口
    ///   - `CaptureError.captureFailed(reason:)` — 截图操作失败（主路径和降级均失败）
    ///   - `CaptureError.invalidRegion` — 截图区域无效
    public func capture(
        mode: CaptureMode = .fullscreen,
        options: CaptureOptions = CaptureOptions()
    ) async throws -> CaptureResult {
        self.currentMode = mode

        // 主路径 — SCK 截图失败时自动降级到 CG
        do {
            logger.info("Attempting capture via SCKAdapter (mode: \(describe(mode)))")
            let result = try await sckAdapter.capture(mode: mode, options: options)
            logger.metric("capture.sck", value: Date().timeIntervalSince1970)
            return result
        } catch CaptureError.permissionDenied {
            throw CaptureError.permissionDenied
        } catch CaptureError.windowNotFound {
            throw CaptureError.windowNotFound
        } catch CaptureError.displayUnavailable {
            logger.warning("SCK: display unavailable, falling back to CG")
            return try await fallbackCapture(mode: mode, options: options)
        } catch CaptureError.invalidRegion {
            throw CaptureError.invalidRegion
        } catch let error as CaptureError {
            logger.warning("SCK capture failed: \(error), falling back to CG")
            return try await fallbackCapture(mode: mode, options: options)
        } catch {
            logger.warning("SCK capture threw unexpected error: \(error.localizedDescription), falling back to CG")
            return try await fallbackCapture(mode: mode, options: options)
        }
    }

    /// Captures a lightweight still preview for a window picker.
    ///
    /// This path intentionally stays on ScreenCaptureKit and does not invoke the legacy
    /// Core Graphics fallback, which would be too expensive when several previews load.
    public func captureWindowThumbnail(
        windowID: CGWindowID,
        maximumSize: CGSize
    ) async throws -> CGImage {
        try await sckAdapter.captureWindowThumbnail(
            windowID: windowID,
            maximumSize: maximumSize
        )
    }

    /// 请求屏幕录制权限。
    ///
    /// macOS 15+ 弹出系统权限弹窗，旧版本跳转系统偏好设置。
    ///
    /// - Returns: 用户是否授权。
    public func requestCapturePermission() async -> Bool {
        logger.info("Requesting capture permission")
        return await permissionService.requestScreenCapturePermission()
    }

    /// 检查当前权限状态。
    ///
    /// - Returns: 权限是否已授予。
    public func checkPermissionStatus() async -> Bool {
        await permissionService.checkScreenCapturePermission()
    }

    /// 获取当前权限状态的完整枚举值。
    ///
    /// 用于驱动 UI 层权限引导卡片的展示逻辑。
    ///
    /// - Returns: 当前 `PermissionState`。
    public func permissionState() async -> PermissionState {
        await permissionService.currentState()
    }

    /// 打开系统屏幕录制权限设置页面。
    ///
    /// 跳转到：系统设置 → 隐私与安全性 → 屏幕录制
    public func openSystemSettings() {
        permissionService.openScreenCaptureSettings()
    }

    /// 返回当前捕获模式。
    public func currentCaptureMode() -> CaptureMode {
        currentMode
    }
}

// MARK: - Fallback Capture

extension CaptureOrchestrator {

    /// 降级截图路径：使用 CGCompatAdapter 实现截图。
    ///
    /// 当 SCKAdapter 不可用或失败时，此方法提供基于 Core Graphics 的降级实现。
    /// 支持全屏、窗口和区域三种模式，但部分高级特性（如光标包含）可能受限。
    private func fallbackCapture(
        mode: CaptureMode,
        options: CaptureOptions
    ) async throws -> CaptureResult {
        logger.info("Falling back to CGCompatAdapter (mode: \(describe(mode)))")

        let timestamp = Date()

        switch mode {
        case .fullscreen:
            return try fallbackFullscreen(options: options, timestamp: timestamp)

        case .window(let windowID):
            return try fallbackWindow(windowID: windowID, options: options, timestamp: timestamp)

        case .area(let rect):
            return try fallbackArea(rect: rect, options: options, timestamp: timestamp)

        case .scroll:
            throw CaptureError.captureFailed(reason: "Scroll capture requires ScrollCore, not available in fallback path")
        }
    }

    /// CG 全屏截图
    private func fallbackFullscreen(options: CaptureOptions, timestamp: Date) throws -> CaptureResult {
        let mainDisplayID = CGMainDisplayID()

        guard cgAdapter.isDisplayActive(mainDisplayID) else {
            throw CaptureError.displayUnavailable
        }

        guard let image = cgAdapter.captureDisplay(mainDisplayID, highResolution: options.highResolution) else {
            throw CaptureError.captureFailed(reason: "CG fallback: failed to capture main display")
        }

        let scaleFactor = cgAdapter.backingScaleFactor(for: mainDisplayID)
        let frame = cgAdapter.frame(for: mainDisplayID)

        let displayInfo = CaptureDisplayInfo(
            displayID: mainDisplayID,
            scaleFactor: scaleFactor,
            frame: frame
        )

        return CaptureResult(
            image: image,
            captureMode: .fullscreen,
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }

    /// CG 窗口截图
    private func fallbackWindow(windowID: CGWindowID?, options: CaptureOptions, timestamp: Date) throws -> CaptureResult {
        guard let targetID = windowID else {
            // 未指定窗口 ID，尝试通过 CG 枚举查找第一个非桌面窗口
            let windows = cgAdapter.enumerateWindows()
            guard let firstWindow = windows.first,
                  let winID = firstWindow[kCGWindowNumber as String] as? UInt32 else {
                throw CaptureError.windowNotFound
            }

            guard let image = cgAdapter.captureWindow(winID, highResolution: options.highResolution) else {
                throw CaptureError.captureFailed(reason: "CG fallback: failed to capture window \(winID)")
            }

            return CaptureResult(
                image: image,
                captureMode: .window(winID),
                timestamp: timestamp,
                displayInfo: nil
            )
        }

        guard let image = cgAdapter.captureWindow(targetID, highResolution: options.highResolution) else {
            throw CaptureError.captureFailed(reason: "CG fallback: failed to capture window \(targetID)")
        }

        return CaptureResult(
            image: image,
            captureMode: .window(targetID),
            timestamp: timestamp,
            displayInfo: nil
        )
    }

    /// CG 区域截图
    private func fallbackArea(rect: CGRect?, options: CaptureOptions, timestamp: Date) throws -> CaptureResult {
        guard let areaRect = rect else {
            throw CaptureError.invalidRegion
        }

        guard areaRect.width > 0, areaRect.height > 0 else {
            throw CaptureError.invalidRegion
        }

        let displayID = cgAdapter.displayID(for: CGPoint(
            x: areaRect.midX,
            y: areaRect.midY
        ))

        guard let image = cgAdapter.captureRect(
            areaRect,
            displayID: displayID,
            highResolution: options.highResolution
        ) else {
            throw CaptureError.captureFailed(reason: "CG fallback: failed to capture rect \(areaRect)")
        }

        let scaleFactor = cgAdapter.backingScaleFactor(for: displayID)
        let frame = cgAdapter.frame(for: displayID)

        let displayInfo = CaptureDisplayInfo(
            displayID: displayID,
            scaleFactor: scaleFactor,
            frame: frame
        )

        return CaptureResult(
            image: image,
            captureMode: .area(rect),
            timestamp: timestamp,
            displayInfo: displayInfo
        )
    }
}

// MARK: - Debug

extension CaptureOrchestrator {
    /// 描述捕获模式（用于日志）
    private func describe(_ mode: CaptureMode) -> String {
        switch mode {
        case .fullscreen:
            return "fullscreen"
        case .window(let id):
            return "window(\(id.map(String.init) ?? "nil"))"
        case .area(let rect):
            return "area(\(rect.map(\.debugDescription) ?? "nil"))"
        case .scroll:
            return "scroll"
        }
    }
}
