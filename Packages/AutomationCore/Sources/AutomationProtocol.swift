import Foundation

// MARK: - 退出码

/// CLI exit codes as defined in the SnapGlass design document.
///
/// Each code corresponds to a specific error category, allowing scripts
/// to branch on the exit code for automated workflows.
public enum ExitCode: Int32, Sendable {
    /// Operation completed successfully.
    case success = 0
    /// Unspecified general error.
    case general = 1
    /// Invalid or missing command-line arguments.
    case argument = 2
    /// Insufficient permission (e.g. screen capture not granted).
    case permission = 3
    /// OCR or barcode engine error (unavailable, recognition failed).
    case engine = 4
    /// File not found, unreadable, or unsupported format.
    case file = 5
}

// MARK: - 自动化命令

/// 统一自动化命令模型，覆盖 CLI、URL Scheme 和 Shortcuts 所有入口。
///
/// CLI 命令格式（源自设计文档 `§四` 和 `§十一`）:
/// ```
/// snapglass-cli ocr file <path> [--engine <vision|tesseract>] [--lang <code>] [--dev-compare] [--format json]
/// snapglass-cli barcode file <path> [--types <qr,code128,...>] [--format json]
/// snapglass-cli dev logs [--format json] [--output <path>]
/// ```
public enum AutomationCommand: Sendable {
    /// 截图命令: `capture --mode <area|window|fullscreen> [--output <path>]`
    case capture(mode: String?, output: String?)

    /// OCR 文字识别命令: `ocr file <path> [--engine <engine>] [--lang <code>] [--dev-compare] [--format json]`
    /// - Parameters:
    ///   - file: 图片文件路径
    ///   - engine: OCR 引擎（`"vision"` 或 `"tesseract"`），nil 使用默认
    ///   - languages: 识别语言列表
    ///   - devCompare: 开发者模式引擎对比
    ///   - outputFormat: 输出格式（`"json"` 或 nil 表示纯文本）
    case ocr(file: String, engine: String?, languages: [String]?, devCompare: Bool = false, outputFormat: String? = nil)

    /// 条码识别命令: `barcode file <path> [--types <type1,type2>] [--format json]`
    /// - Parameters:
    ///   - file: 图片文件路径
    ///   - types: 要检测的条码类型，nil 表示全部类型
    ///   - outputFormat: 输出格式（`"json"` 或 nil 表示纯文本）
    case barcode(file: String, types: [String]?, outputFormat: String? = nil)

    /// 历史记录管理命令: `history <list|search|delete|export|clear>`
    case history(subcommand: HistorySubcommand)

    /// 开发者工具命令: `dev logs [--format json] [--output <path>]`
    case dev(subcommand: DevSubcommand)

    /// 偏好设置命令: `preferences --key <key> [--value <value>]`
    case preferences(key: String?, value: String?)

    // MARK: - 历史子命令

    /// 历史记录子命令枚举
    public enum HistorySubcommand: String, Sendable {
        /// 列出所有历史条目
        case list
        /// 搜索历史（按关键词）
        case search
        /// 删除指定历史条目
        case delete
        /// 导出历史数据
        case export
        /// 清空所有历史
        case clear
    }

    // MARK: - 开发者子命令

    /// 开发者工具子命令枚举
    public enum DevSubcommand: Sendable {
        /// 导出开发者模式日志: `dev logs [--format json] [--output <path>]`
        ///
        /// 将 `DevModeService` 中的引擎对比日志导出为 JSON 格式。
        /// - Parameters:
        ///   - format: 输出格式（`"json"` 或 nil 表示纯文本）
        ///   - output: 输出文件路径，nil 表示 stdout
        case logs(format: String?, output: String?)

        /// 开发者模式引擎对比: 同时运行 Vision 和 Tesseract 并输出对比结果
        /// - Parameters:
        ///   - file: 图片文件路径
        ///   - languages: 识别语言列表
        case compare(file: String, languages: [String]?)
    }
}

// MARK: - 自动化协议

public protocol AutomationProtocol: Sendable {
    func execute(_ command: AutomationCommand) async throws -> AutomationResult
}

// MARK: - 自动化结果

public struct AutomationResult: Sendable {
    public let success: Bool
    public let output: String
    public let data: Data?
    public let exitCode: Int32

    public init(success: Bool, output: String, data: Data? = nil, exitCode: ExitCode = .success) {
        self.success = success
        self.output = output
        self.data = data
        self.exitCode = exitCode.rawValue
    }
}

// MARK: - 自动化错误

public enum AutomationError: Error, Sendable {
    case invalidCommand(String)
    case fileNotFound(String)
    case permissionDenied
    case outputFileError(String)
    case missingArgument(String)
    case engineError(String)
}

extension AutomationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCommand(let cmd):
            return "无效命令: \(cmd)。使用 --help 查看可用命令。"
        case .fileNotFound(let path):
            return "文件未找到: \(path)"
        case .permissionDenied:
            return "权限不足，请检查系统权限设置。"
        case .outputFileError(let path):
            return "无法写入输出文件: \(path)"
        case .missingArgument(let arg):
            return "缺少必要参数: \(arg)"
        case .engineError(let reason):
            return "引擎错误: \(reason)"
        }
    }
}
