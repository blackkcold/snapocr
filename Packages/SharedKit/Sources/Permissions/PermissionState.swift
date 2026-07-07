import Foundation

/// 屏幕录制权限状态
///
/// 表示屏幕录制权限的完整生命周期状态，
/// 与设计文档 Section 7.2 权限状态机一致。
///
/// 状态迁移：
/// ```
/// unknown ──checkPermission()──▶ granted / denied
/// requesting ──用户响应──▶ granted / denied
/// granted / denied ──功能受限──▶ degraded
/// ```
public enum PermissionState: String, Sendable, CaseIterable {
    /// 初始状态，尚未检查权限
    case unknown

    /// 正在请求权限（用户正在系统弹窗中做选择）
    case requesting

    /// 权限已授权，可以使用屏幕录制功能
    case granted

    /// 权限被用户拒绝
    case denied

    /// 降级模式：权限不可用，功能受限运行
    /// 展示引导卡片，仅禁用对应能力，其他功能正常
    case degraded
}

// MARK: - 状态查询

extension PermissionState {
    /// 权限是否已授权，可以正常使用
    public var isAuthorized: Bool {
        self == .granted
    }

    /// 是否需要展示权限引导 UI
    public var needsGuide: Bool {
        switch self {
        case .unknown, .denied, .degraded:
            return true
        case .requesting, .granted:
            return false
        }
    }

    /// 权限是否处于不可用状态（拒绝或降级）
    public var isUnavailable: Bool {
        switch self {
        case .denied, .degraded:
            return true
        case .unknown, .requesting, .granted:
            return false
        }
    }
}

// MARK: - 本地化描述

extension PermissionState {
    /// 状态的中文描述
    public var localizedDescription: String {
        switch self {
        case .unknown:
            return String(localized: "未检查权限")
        case .requesting:
            return String(localized: "正在请求权限")
        case .granted:
            return String(localized: "权限已授权")
        case .denied:
            return String(localized: "权限被拒绝")
        case .degraded:
            return String(localized: "降级模式")
        }
    }
}
