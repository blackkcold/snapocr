import CoreGraphics
import Foundation

// MARK: - ScrollProtocol

/// 滚动截图捕获协议。
///
/// 定义半自动滚动截图的核心接口，提供从启动捕获、逐帧采集、
/// 拼接合并到取消操作的全生命周期管理。
///
/// 所有遵循此协议的实现必须在并发环境中安全使用（`Sendable`）。
///
/// ## 典型使用流程
/// ```swift
/// let engine = ScrollStitchActor()
/// let session = try await engine.startCapture(windowID: safariWindowID)
///
/// for await frame in engine.captureStream(session) {
///     // 显示实时进度
///     updateProgress(frame.index)
/// }
///
/// let stitchedImage = try await engine.stitchFrames(allFrames)
/// ```
///
/// ## 白名单策略（设计文档 §R2）
/// 首版仅支持 Safari 和 Chrome 的滚动截图。
/// 白名单外的应用返回 `ScrollError.applicationNotSupported`，
/// 并引导用户使用手动截图方式。
public protocol ScrollProtocol: Sendable {
    /// 启动滚动截图会话。
    ///
    /// 根据指定的窗口标识符创建新的截图会话。
    /// 实现需校验目标应用是否在白名单中，白名单外应用抛出错误。
    ///
    /// - Parameter windowID: 目标窗口的 `CGWindowID`。
    /// - Returns: 初始化后的 `ScrollSession`，状态为 `.ready`。
    /// - Throws: `ScrollError` — 窗口不存在、应用不支持、权限不足等。
    func startCapture(windowID: CGWindowID) async throws -> ScrollSession

    /// 捕获下一帧画面。
    ///
    /// 在当前会话中截取窗口的当前可见区域，生成带有
    /// 索引号和时间戳的 `ScrollFrame`。
    ///
    /// - Parameter session: 当前活跃的截图会话。
    /// - Returns: 新捕获的 `ScrollFrame`，包含 `CGImage` 和元数据。
    /// - Throws: `ScrollError` — 会话无效、捕获超时、重复帧检测等。
    func captureNextFrame(session: ScrollSession) async throws -> ScrollFrame

    /// 将多个帧拼接为完整长图。
    ///
    /// 对帧数组进行去重、重叠检测后执行像素级拼接，
    /// 生成包含所有滚动内容的单一图像。
    ///
    /// - Parameter frames: 按捕获顺序排列的帧数组，至少需要 2 帧。
    /// - Returns: 拼接完成的 `CGImage`。
    /// - Throws: `ScrollError` — 帧数不足、拼接受损、内存不足等。
    func stitchFrames(_ frames: [ScrollFrame]) async throws -> CGImage

    /// 取消当前截图会话。
    ///
    /// 中止捕获并释放所有已分配资源。
    /// 已经拼接完成的图像不受影响。
    ///
    /// - Parameter session: 要取消的截图会话。
    func cancelCapture(session: ScrollSession) async
}

// MARK: - ScrollSession

/// 滚动截图会话。
///
/// 封装一次完整滚动截图操作的状态信息，
/// 包括目标窗口、帧计数和当前状态。
///
/// 遵循 `Identifiable` 以支持 SwiftUI 列表渲染，
/// 遵循 `Sendable` 以确保并发安全。
public struct ScrollSession: Sendable, Identifiable {
    /// 会话唯一标识符
    public let id: UUID
    /// 目标窗口的 `CGWindowID`
    public let windowID: CGWindowID
    /// 已捕获的帧数量
    public var capturedFrames: Int
    /// 当前会话状态
    public var status: ScrollSessionStatus

    /// 创建新的截图会话。
    ///
    /// - Parameter windowID: 目标窗口标识符。
    public init(windowID: CGWindowID) {
        self.id = UUID()
        self.windowID = windowID
        self.capturedFrames = 0
        self.status = .ready
    }
}

// MARK: - ScrollSessionStatus

/// 滚动截图会话状态。
///
/// 追踪从就绪到完成（或失败、取消）的完整生命周期。
/// 遵循 `Sendable`，可在 actor 间安全传递。
public enum ScrollSessionStatus: Sendable {
    /// 会话已创建，等待开始
    case ready
    /// 正在捕获帧
    case capturing
    /// 正在执行帧拼接
    case stitching
    /// 拼接完成，结果可用
    case completed
    /// 发生错误，关联错误详情
    case failed(ScrollError)
    /// 用户主动取消
    case cancelled
}

// MARK: - ScrollFrame

/// 单帧截图数据。
///
/// 包含一帧截图图像及其元数据：
/// 索引（在序列中的位置）、时间戳、
/// 以及用于重叠检测的预估滚动偏移量。
public struct ScrollFrame: Sendable {
    /// 帧图像数据
    public let image: CGImage
    /// 帧在捕获序列中的索引（从 0 开始）
    public let index: Int
    /// 帧捕获的时间戳
    public let timestamp: Date
    /// 相对于前一帧的预估滚动偏移量（像素）
    ///
    /// 正值表示向下滚动，负值表示向上滚动。
    /// 用于估算相邻帧之间的重叠区域。
    public let predictedScrollOffset: CGFloat

    /// 创建新的帧对象。
    ///
    /// - Parameters:
    ///   - image: 帧图像。
    ///   - index: 序列索引。
    ///   - timestamp: 捕获时间。
    ///   - predictedScrollOffset: 预估滚动偏移。
    public init(
        image: CGImage,
        index: Int,
        timestamp: Date = Date(),
        predictedScrollOffset: CGFloat = 0
    ) {
        self.image = image
        self.index = index
        self.timestamp = timestamp
        self.predictedScrollOffset = predictedScrollOffset
    }
}

// MARK: - ScrollError

/// 滚动截图错误类型。
///
/// 涵盖滚动截图全生命周期中可能出现的各类错误，
/// 包括窗口不可用、超时、拼接失败、应用不支持等场景。
/// 遵循 `Sendable` 以支持并发安全传递。
public enum ScrollError: Error, Sendable, LocalizedError {
    /// 未找到指定窗口
    /// - Parameter CGWindowID: 无效的窗口标识符。
    case windowNotFound(CGWindowID)
    /// 帧捕获超时（超过最大等待时间）
    case captureTimeout
    /// 帧拼接失败
    /// - Parameter reason: 失败原因描述。
    case stitchFailed(reason: String)
    /// 帧数不足，至少需要 2 帧才能拼接
    /// - Parameter count: 实际提供的帧数。
    case insufficientFrames(count: Int)
    /// 目标应用不在白名单中
    /// - Parameter String: 应用的 bundle identifier 或名称。
    case applicationNotSupported(String)
    /// 检测到重复帧
    /// - Parameter index: 重复帧的索引。
    case duplicateFrameDetected(index: Int)
    /// 内存压力过高，无法继续操作
    case memoryPressureHigh
    /// 会话无效或已结束
    case invalidSession
    /// 帧尺寸不一致，无法拼接
    /// - Parameter details: 不一致的具体描述。
    case frameMismatch(details: String)

    public var errorDescription: String? {
        switch self {
        case .windowNotFound:
            return "未找到目标窗口"
        case .captureTimeout:
            return "滚动截图超时"
        case .stitchFailed(let reason):
            return "滚动截图拼接失败: \(reason)"
        case .insufficientFrames(let count):
            return "至少需要 2 帧才能拼接，当前为 \(count) 帧"
        case .applicationNotSupported(let bundleID):
            return "暂不支持该应用（\(bundleID)），当前支持 Safari 和 Google Chrome"
        case .duplicateFrameDetected:
            return "画面没有发生变化，请滚动后重试"
        case .memoryPressureHigh:
            return "内存压力过高，请结束其他高占用任务后重试"
        case .invalidSession:
            return "滚动截图会话已失效"
        case .frameMismatch(let details):
            return "截图帧尺寸不一致: \(details)"
        }
    }
}

// MARK: - ScrollProgress

/// 滚动截图进度报告。
///
/// 用于向 UI 层报告实时捕获进度，
/// 包括帧计数、内存使用和状态摘要。
/// 遵循 `Sendable` 以支持 actor 间传递。
public struct ScrollProgress: Sendable {
    /// 已捕获的帧数
    public let capturedFrames: Int
    /// 预估的总帧数（如果可计算）
    public let estimatedTotalFrames: Int?
    /// 累计滚动距离（像素）
    public let scrollDistance: CGFloat
    /// 当前内存使用量（字节），通过 `task_info` 获取
    public let memoryUsage: UInt64
    /// 当前会话状态
    public let status: ScrollSessionStatus
    /// 当前内存压力级别
    public let memoryPressure: MemoryPressureLevel

    /// 创建进度报告。
    ///
    /// - Parameters:
    ///   - capturedFrames: 已捕获帧数。
    ///   - estimatedTotalFrames: 预估总帧数。
    ///   - scrollDistance: 累计滚动距离。
    ///   - memoryUsage: 当前内存用量。
    ///   - status: 会话状态。
    ///   - memoryPressure: 内存压力级别。
    public init(
        capturedFrames: Int,
        estimatedTotalFrames: Int? = nil,
        scrollDistance: CGFloat = 0,
        memoryUsage: UInt64 = 0,
        status: ScrollSessionStatus = .capturing,
        memoryPressure: MemoryPressureLevel = .normal
    ) {
        self.capturedFrames = capturedFrames
        self.estimatedTotalFrames = estimatedTotalFrames
        self.scrollDistance = scrollDistance
        self.memoryUsage = memoryUsage
        self.status = status
        self.memoryPressure = memoryPressure
    }
}

// MARK: - MemoryPressureLevel

/// 内存压力级别（设计文档 §附录 E）。
///
/// 定义四级内存压力，每级对应不同的响应策略：
/// | 级别 | 阈值 | 响应措施 |
/// |------|------|----------|
/// | normal | < 150MB | 无限制运行 |
/// | moderate | 150–200MB | 限制帧缓存数量 |
/// | high | > 200MB | 暂停新帧采集，降采样处理 |
/// | critical | > 300MB | 释放所有非活跃缓存，显示警告 |
public enum MemoryPressureLevel: Int, Sendable, Comparable {
    /// 正常（< 150MB）：无限制
    case normal = 0
    /// 中等压力（150–200MB）：减少缓存
    case moderate = 1
    /// 高压力（> 200MB）：暂停新帧、降采样
    case high = 2
    /// 临界压力（> 300MB）：强制释放缓存
    case critical = 3

    public static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ScrollWhitelist

/// 滚动截图白名单应用列表。
///
/// 首版仅支持经过验证的应用，确保拼接质量（设计文档 §R2）。
/// 白名单外的应用返回 `ScrollError.applicationNotSupported`，
/// 引导用户使用手动截图方式。
public struct ScrollWhitelist: Sendable {
    /// 支持滚动截图的应用 bundle identifier 集合
    public static let supportedBundleIDs: Set<String> = [
        "com.apple.Safari",        // Safari
        "com.google.Chrome",       // Google Chrome
    ]

    /// 检查指定 bundle identifier 是否在白名单中。
    ///
    /// - Parameter bundleID: 应用的 bundle identifier。
    /// - Returns: 如果支持滚动截图返回 `true`，否则返回 `false`。
    public static func isSupported(_ bundleID: String) -> Bool {
        supportedBundleIDs.contains(bundleID)
    }

    /// 获取支持应用的友好名称列表。
    ///
    /// - Returns: 应用名称数组，用于 UI 提示。
    public static func supportedAppNames() -> [String] {
        ["Safari", "Google Chrome"]
    }
}
