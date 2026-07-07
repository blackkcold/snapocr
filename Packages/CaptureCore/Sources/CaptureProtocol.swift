import CoreGraphics
import Foundation

// MARK: - CaptureMode

/// 截图捕获模式。
///
/// 定义截图的目标类型，支持区域、窗口、全屏和滚动截图四种模式。
/// 遵循 `Sendable` 协议，可在并发环境安全传递。
public enum CaptureMode: Sendable {
    /// 区域截图，关联可选的矩形区域（以屏幕坐标表示）。
    /// 当 `CGRect` 为 `nil` 时，表示用户尚未选定区域。
    case area(CGRect?)
    /// 窗口截图，关联可选的窗口标识符。
    /// 当 `CGWindowID` 为 `nil` 时，表示需要用户选择窗口。
    case window(CGWindowID?)
    /// 全屏截图，捕获主显示器的完整画面。
    case fullscreen
    /// 滚动截图，捕获超出可见区域的完整内容。
    case scroll
}

// MARK: - CaptureError

/// 截图捕获错误类型。
///
/// 涵盖截图过程中可能出现的各类错误，包括权限、设备、参数等方面。
public enum CaptureError: Error, Sendable, LocalizedError {
    /// 用户拒绝了屏幕录制权限
    case permissionDenied
    /// 指定的显示器不可用或已断开
    case displayUnavailable
    /// 未找到指定的窗口
    case windowNotFound
    /// 截图操作失败，附带失败原因描述
    case captureFailed(reason: String)
    /// 指定的截图区域无效（如尺寸为零或超出屏幕范围）
    case invalidRegion

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "截图权限被拒绝"
        case .displayUnavailable:
            return "显示器不可用"
        case .windowNotFound:
            return "未找到指定窗口"
        case .captureFailed(let reason):
            return "截图失败: \(reason)"
        case .invalidRegion:
            return "截图区域无效"
        }
    }
}

// MARK: - CaptureOptions

/// 截图捕获选项。
///
/// 控制截图行为，包括是否包含光标、是否使用高分辨率、首选缩放因子等。
public struct CaptureOptions: Sendable {
    /// 是否在截图中包含光标
    public let includeCursor: Bool
    /// 是否使用高分辨率（Retina）进行截图
    public let highResolution: Bool
    /// 首选缩放因子（2.0 对应 Retina，1.0 对应标准分辨率）
    public let preferredScaleFactor: CGFloat

    /// 创建截图选项。
    ///
    /// - Parameters:
    ///   - includeCursor: 是否包含光标，默认为 `true`。
    ///   - highResolution: 是否使用高分辨率，默认为 `true`。
    ///   - preferredScaleFactor: 首选缩放因子，默认为 `2.0`。
    public init(
        includeCursor: Bool = true,
        highResolution: Bool = true,
        preferredScaleFactor: CGFloat = 2.0
    ) {
        self.includeCursor = includeCursor
        self.highResolution = highResolution
        self.preferredScaleFactor = preferredScaleFactor
    }
}

// MARK: - CaptureDisplayInfo

/// 显示器信息。
///
/// 记录截图来源显示器的标识符、缩放因子和帧信息，
/// 用于多显示器场景下的 DPI 差异处理。
public struct CaptureDisplayInfo: Sendable {
    /// 显示器的 `CGDirectDisplayID` 标识符
    public let displayID: UInt32
    /// 显示器的缩放因子（2.0 为 Retina，1.0 为标准）
    public let scaleFactor: CGFloat
    /// 显示器在全局坐标系中的帧
    public let frame: CGRect
}

// MARK: - CaptureResult

/// 截图结果。
///
/// 包含截图生成的 `CGImage`、捕获模式、时间戳和来源显示器信息。
public struct CaptureResult: Sendable {
    /// 截图生成的 `CGImage`
    public let image: CGImage
    /// 使用的捕获模式
    public let captureMode: CaptureMode
    /// 截图时间戳
    public let timestamp: Date
    /// 来源显示器信息（可选，区域/窗口截图为 `nil` 时需根据上下文推断）
    public let displayInfo: CaptureDisplayInfo?
}

// MARK: - CaptureProtocol

/// 跨平台截图捕获协议。
///
/// 定义截图功能的核心接口，所有平台适配器（`SCKAdapter`、`CGCompatAdapter` 等）
/// 均需遵循此协议。通过 `CaptureProtocol`，上层模块可以统一调用截图功能，
/// 而无需关心底层具体实现。
///
/// 遵循 `Sendable` 协议确保可在并发环境中安全传递。
///
/// 使用示例:
/// ```swift
/// let adapter: any CaptureProtocol = SCKAdapter()
/// let result = try await adapter.capture(mode: .fullscreen, options: .init())
/// ```
public protocol CaptureProtocol: Sendable {
    /// 执行截图捕获。
    ///
    /// 根据指定的模式（区域/窗口/全屏）和选项执行截图操作。
    /// 此方法为异步方法，需在 `Task` 或 `async` 上下文中调用。
    ///
    /// - Parameters:
    ///   - mode: 捕获模式，指定截图目标类型（区域、窗口、全屏或滚动）。
    ///   - options: 捕获选项，控制截图行为（如分辨率、光标等）。
    /// - Returns: 包含截图结果 `CaptureResult`，其中包含 `CGImage`、时间戳等信息。
    /// - Throws: `CaptureError.permissionDenied` — 权限被拒绝；
    ///           `CaptureError.displayUnavailable` — 显示器不可用；
    ///           `CaptureError.windowNotFound` — 未找到指定窗口；
    ///           `CaptureError.captureFailed(reason:)` — 截图操作失败；
    ///           `CaptureError.invalidRegion` — 指定区域无效。
    func capture(mode: CaptureMode, options: CaptureOptions) async throws -> CaptureResult

    /// 返回当前适配器支持的捕获模式列表。
    ///
    /// 根据系统能力和当前配置，动态返回可用模式。
    /// 例如，当未检测到显示器时，`fullscreen` 不可用。
    ///
    /// - Returns: 当前可用的 `CaptureMode` 数组。
    func availableCaptureModes() async -> [CaptureMode]

    /// 请求屏幕录制权限。
    ///
    /// 触发系统的权限请求流程（macOS 15+ 为系统弹窗，旧版本跳转系统偏好设置）。
    /// 请求完成后返回授权结果。
    ///
    /// - Returns: 权限是否已授权。
    func requestPermission() async -> Bool

    /// 检查当前屏幕录制权限状态。
    ///
    /// 使用双重验证策略确保结果准确：
    /// 1. `CGPreflightScreenCaptureAccess()` 快速预检
    /// 2. 实际尝试获取 `SCShareableContent` 确认
    ///
    /// - Returns: 权限是否已授予。
    func checkPermissionStatus() async -> Bool
}
