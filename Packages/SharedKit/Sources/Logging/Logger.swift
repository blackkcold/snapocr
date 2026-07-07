import Foundation
import OSLog

/// 统一日志接口
///
/// 提供结构化的日志记录能力，支持不同级别和分类。
/// 底层使用 `os_log` 进行系统级日志输出，可在 Console.app 中查看。
///
/// 使用示例:
/// ```swift
/// let logger = Logger(category: "history")
/// logger.info("历史记录加载完成")
/// logger.warning("存储空间即将耗尽")
/// logger.error("加密失败", error: cryptoError)
/// ```
public struct Logger: Sendable {
    /// 系统日志对象
    private let osLog: OSLog

    /// 当前日志过滤器级别，低于此级别的日志将被忽略
    public var logLevel: LogLevel = .info

    /// 创建新的日志实例
    ///
    /// - Parameters:
    ///   - subsystem: 日志子系统标识，通常为 bundle identifier。
    ///   - category: 日志分类，用于在 Console.app 中过滤和组织日志。
    ///   - logLevel: 最低输出级别，低于此级别的日志不会记录。默认为 `.info`。
    public init(
        subsystem: String = "com.snapglass",
        category: String = "general",
        logLevel: LogLevel = .info
    ) {
        self.osLog = OSLog(subsystem: subsystem, category: category)
        self.logLevel = logLevel
    }

    /// 记录调试信息（仅在 Debug 构建中输出）
    ///
    /// - Parameter message: 调试消息内容。
    public func debug(_ message: String) {
        guard logLevel <= .debug else { return }
        os_log(.debug, log: osLog, "%{public}@", message)
    }

    /// 记录常规信息
    ///
    /// - Parameter message: 信息消息内容。
    public func info(_ message: String) {
        guard logLevel <= .info else { return }
        os_log(.info, log: osLog, "%{public}@", message)
    }

    /// 记录警告信息
    ///
    /// 用于不影响功能但需要注意的情况。
    ///
    /// - Parameter message: 警告消息内容。
    public func warning(_ message: String) {
        guard logLevel <= .warning else { return }
        os_log(.default, log: osLog, "%{public}@", message)
    }

    /// 记录错误信息
    ///
    /// 用于功能可能出现异常的情况，可附带 `Error` 详情。
    ///
    /// - Parameters:
    ///   - message: 错误描述。
    ///   - error: 可选的 `Error` 实例，其描述会被附加到日志中。
    public func error(_ message: String, error: (any Error)? = nil) {
        guard logLevel <= .error else { return }
        if let error {
            os_log(.error, log: osLog, "%{public}@: %{public}@", message, error.localizedDescription)
        } else {
            os_log(.error, log: osLog, "%{public}@", message)
        }
    }

    /// 记录性能指标
    ///
    /// 以统一的 `[Metric]` 格式输出到 Info 级别，便于在 Console.app 中聚合分析。
    ///
    /// - Parameters:
    ///   - name: 指标名称，如 `"ocr.recognition"`。
    ///   - value: 指标数值。
    ///   - unit: 单位，默认为 `"ms"`。
    public func metric(_ name: String, value: Double, unit: String = "ms") {
        let formatted = String(format: "[Metric] %@: %.2f %@", name, value, unit)
        os_log(.info, log: osLog, "%{public}@", formatted)
    }
}
