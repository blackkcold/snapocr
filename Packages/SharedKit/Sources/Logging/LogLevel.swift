/// 日志级别枚举
public enum LogLevel: String, Sendable, Comparable {
    /// 调试信息，仅在开发环境可见
    case debug
    /// 常规信息，用于追踪正常流程
    case info
    /// 警告，不影响功能但需要注意
    case warning
    /// 错误，功能可能出现异常
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel: Int] = [.debug: 0, .info: 1, .warning: 2, .error: 3]
        return order[lhs, default: 0] < order[rhs, default: 0]
    }
}
