import Foundation

public struct CommandParser: Sendable {

    public init() {}

    public func parse(_ arguments: [String]) throws -> AutomationCommand {
        guard let command = arguments.first else {
            throw AutomationError.invalidCommand("未指定命令。使用 --help 查看可用命令。")
        }

        let args = Array(arguments.dropFirst())
        switch command {
        case "capture":
            return parseCapture(args)
        case "ocr":
            return try parseOCR(args)
        case "barcode":
            return try parseBarcode(args)
        case "dev":
            return try parseDev(args)
        case "history":
            return parseHistory(args)
        case "preferences":
            return parsePreferences(args)
        default:
            throw AutomationError.invalidCommand("未知命令: \(command)。使用 --help 查看可用命令。")
        }
    }

    private func parseCapture(_ args: [String]) -> AutomationCommand {
        .capture(mode: parseArg(args, named: "--mode"), output: parseArg(args, named: "--output"))
    }

    private func parseOCR(_ args: [String]) throws -> AutomationCommand {
        // 支持 `ocr file <path>` 子命令语法（设计文档推荐格式）
        if args.first == "file" {
            let subArgs = Array(args.dropFirst())
            guard let file = subArgs.first, !file.hasPrefix("--") else {
                throw AutomationError.missingArgument("ocr file 需要指定文件路径")
            }
            let remaining = Array(subArgs.dropFirst())
            return buildOCRCommand(file: file, args: remaining)
        }
        // 向后兼容 `ocr --file <path>` 标志语法
        guard let file = parseArg(args, named: "--file") else {
            throw AutomationError.missingArgument("ocr 需要指定文件: ocr file <path> 或 ocr --file <path>")
        }
        return buildOCRCommand(file: file, args: args)
    }

    /// 从已解析的选项构建 OCR 命令（两种语法的共享逻辑）。
    private func buildOCRCommand(file: String, args: [String]) -> AutomationCommand {
        let engine = parseArg(args, named: "--engine")
        let lang = parseArg(args, named: "--lang")
            ?? parseArg(args, named: "--language")
        let languages: [String]? = lang.map {
            $0.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        } ?? parseList(args, named: "--languages")
        let devCompare = args.contains("--dev-compare")
        let format = parseArg(args, named: "--format")

        return .ocr(
            file: file,
            engine: engine,
            languages: languages,
            devCompare: devCompare,
            outputFormat: format
        )
    }

    private func parseBarcode(_ args: [String]) throws -> AutomationCommand {
        // 支持 `barcode file <path>` 子命令语法
        if args.first == "file" {
            let subArgs = Array(args.dropFirst())
            guard let file = subArgs.first, !file.hasPrefix("--") else {
                throw AutomationError.missingArgument("barcode file 需要指定文件路径")
            }
            let remaining = Array(subArgs.dropFirst())
            let types = parseList(remaining, named: "--types")
            let format = parseArg(remaining, named: "--format")
            return .barcode(file: file, types: types, outputFormat: format)
        }
        // 向后兼容 `barcode --file <path>` 标志语法
        guard let file = parseArg(args, named: "--file") else {
            throw AutomationError.missingArgument("barcode 需要指定文件: barcode file <path> 或 barcode --file <path>")
        }
        let types = parseList(args, named: "--types")
        let format = parseArg(args, named: "--format")
        return .barcode(file: file, types: types, outputFormat: format)
    }

    private func parseDev(_ args: [String]) throws -> AutomationCommand {
        guard let subcommand = args.first else {
            throw AutomationError.invalidCommand("dev 需要子命令: logs, compare。使用 --help 查看详情。")
        }
        let subArgs = Array(args.dropFirst())
        switch subcommand {
        case "logs":
            return .dev(subcommand: .logs(
                format: parseArg(subArgs, named: "--format"),
                output: parseArg(subArgs, named: "--output")
            ))
        case "compare":
            guard let file = subArgs.first, !file.hasPrefix("--") else {
                throw AutomationError.missingArgument("dev compare 需要指定文件路径")
            }
            let remaining = Array(subArgs.dropFirst())
            let lang = parseArg(remaining, named: "--lang")
            let languages: [String]? = lang.map { [$0] }
            return .dev(subcommand: .compare(file: file, languages: languages))
        default:
            throw AutomationError.invalidCommand("未知 dev 子命令: \(subcommand)。可用: logs, compare")
        }
    }

    private func parseHistory(_ args: [String]) -> AutomationCommand {
        let sub = args.first ?? "list"
        let subcommand = AutomationCommand.HistorySubcommand(rawValue: sub) ?? .list
        return .history(subcommand: subcommand)
    }

    private func parsePreferences(_ args: [String]) -> AutomationCommand {
        .preferences(key: parseArg(args, named: "--key"), value: parseArg(args, named: "--value"))
    }

    private func parseArg(_ args: [String], named: String) -> String? {
        guard let index = args.firstIndex(of: named), index + 1 < args.count else {
            return nil
        }
        let value = args[index + 1]
        guard !value.hasPrefix("--") else { return nil }
        return value
    }

    private func parseList(_ args: [String], named: String) -> [String]? {
        guard let value = parseArg(args, named: named) else { return nil }
        return value.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Help

    /// 返回完整的 CLI 帮助文本，包含所有命令、选项和退出码说明。
    ///
    /// 用法示例:
    /// ```swift
    /// print(CommandParser.helpText())
    /// ```
    public static func helpText() -> String {
        return """
        SnapGlass CLI — macOS 截图与高效 OCR 工具

        用法: snapglass-cli <command> [options]

        命令:
          ocr         OCR 文本识别
          barcode     条码/二维码识别
          capture     截图
          history     历史记录管理
          dev         开发者工具

        OCR:
          snapglass-cli ocr file <path> [--engine <vision|tesseract>] [--lang <code>] [--dev-compare] [--format json]

          选项:
            --engine <vision|tesseract>   OCR 引擎，默认 vision
            --lang <code>                 识别语言，如 chi_sim、eng
            --dev-compare                 同时运行 Vision 和 Tesseract 引擎并输出对比
            --format json                 以 JSON 格式输出结果

          示例:
            snapglass-cli ocr file ./screenshot.png --lang chi_sim
            snapglass-cli ocr file ./sample.png --engine tesseract --lang chi_sim
            snapglass-cli ocr file ./sample.png --dev-compare --format json

        条码:
          snapglass-cli barcode file <path> [--types <type1,type2>] [--format json]

          选项:
            --types <qr,code128,...>      条码类型，默认全部
            --format json                 以 JSON 格式输出结果

          示例:
            snapglass-cli barcode file ./qrcode.png

        截图:
          snapglass-cli capture --mode <area|window|fullscreen> [--output <path>]

        历史:
          snapglass-cli history <list|search|delete|export|clear>

        开发者:
          snapglass-cli dev logs [--format json] [--output <path>]

          示例:
            snapglass-cli dev logs --format json --output ./ocr-compare.json

        退出码 (附录 B):
          0   成功
          1   通用错误
          2   参数错误
          3   权限不足
          4   引擎错误
          5   文件错误
        """
    }
}
