import AppKit
import Foundation
import ScreenCaptureKit

#if canImport(OSLog)
import OSLog
#endif

/// 屏幕录制权限服务
///
/// 负责检查、请求和管理屏幕录制权限状态。
/// 遵循设计文档 Section 7.2 权限状态机设计。
///
/// 权限检查使用双重验证策略：
/// 1. `CGPreflightScreenCaptureAccess()` — 快速预检
/// 2. `SCShareableContent.current` — 实际确认
///
/// > 注意: macOS Sequoia+ 上 `CGPreflightScreenCaptureAccess()` 对临时签名 (debug build)
/// > 始终返回 `false`，因此必须执行第二步验证。
public struct PermissionService: Sendable {
    private let logger: Logger

    /// 创建权限服务实例
    /// - Parameter logger: 日志实例，默认使用 `"permission"` 分类
    public init(logger: Logger = Logger(category: "permission")) {
        self.logger = logger
    }

    /// 检查屏幕录制权限
    ///
    /// 使用双重验证确保结果准确：
    /// - 快速预检: `CGPreflightScreenCaptureAccess()`
    /// - 实际验证: `SCShareableContent.current`
    ///
    /// **重要**: macOS 15 Sequoia+ 对 ad-hoc 签名应用，`CGPreflightScreenCaptureAccess()`
    /// 可能始终返回 `false`。因此不依赖 CGPreflight 作为 guard 条件，
    /// 而是将 `SCShareableContent.current` 作为主要验证手段。
    ///
    /// - Returns: 权限是否已授权
    public func checkScreenCapturePermission() async -> Bool {
        let preflight = CGPreflightScreenCaptureAccess()
        logger.info("CGPreflightScreenCaptureAccess() = \(preflight)")

        do {
            let content = try await SCShareableContent.current
            if !content.displays.isEmpty {
                logger.info("Permission verified via SCShareableContent (displays: \(content.displays.count))")
                return true
            }
            logger.warning("SCShareableContent returned empty displays")
        } catch {
            logger.warning("SCShareableContent failed: \(error.localizedDescription)")
        }

        // 无条件重试一次，不依赖 CGPreflight（macOS 15+ ad-hoc 签名下可能返回 false）
        logger.info("Retrying permission check...")
        try? await Task.sleep(for: .milliseconds(500))
        do {
            let content = try await SCShareableContent.current
            if !content.displays.isEmpty {
                logger.info("Permission verified on retry")
                return true
            }
        } catch {
            logger.warning("Retry failed: \(error.localizedDescription)")
        }

        return false
    }

    /// 请求屏幕录制权限
    ///
    /// macOS 15+ 会触发系统权限弹窗，用户选择后返回结果。
    /// macOS 14 及以下版本会打开系统设置页面，引导用户手动开启。
    ///
    /// - Returns: 用户是否授权
    public func requestScreenCapturePermission() async -> Bool {
        logger.info("Requesting screen capture permission")

        if #available(macOS 15, *) {
            CGRequestScreenCaptureAccess()
        } else {
            openScreenCaptureSettings()
        }

        // 轮询检查，一旦成功立即返回（最多等待 15 秒）
        for i in 0..<15 {
            try? await Task.sleep(for: .seconds(1))
            let granted = await checkScreenCapturePermission()
            if granted {
                logger.info("Permission granted after \(i + 1) seconds")
                return true
            }
        }

        logger.warning("Permission not granted after 15 seconds")
        return false
    }

    /// 打开系统屏幕录制权限设置页面
    ///
    /// 跳转到: 系统设置 → 隐私与安全性 → 屏幕录制
    public func openScreenCaptureSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            logger.error("Failed to create system preferences URL")
            return
        }

        logger.debug("Opening system preferences: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    /// 获取当前权限状态的完整描述
    ///
    /// 通过检查权限并返回对应的 `PermissionState`。
    /// 用于驱动 UI 层的状态展示。
    ///
    /// - Returns: 当前权限状态
    public func currentState() async -> PermissionState {
        let isGranted = await checkScreenCapturePermission()

        if isGranted {
            return .granted
        }

        // 检查 CGPreflight 结果以区分 unknown 和 denied
        // 注意：macOS 15+ 对 ad-hoc 签名应用，CGPreflight 可能始终返回 false
        let preflight = CGPreflightScreenCaptureAccess()
        if preflight {
            // preflight 说有权限但 SCShareableContent 失败 → 降级
            return .degraded
        }

        // 无法确定是 unknown 还是 denied，返回 denied 以触发引导
        return .denied
    }
}
