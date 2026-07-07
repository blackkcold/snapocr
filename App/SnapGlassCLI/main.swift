import Foundation
import AutomationCore
import CaptureCore
import OCRCore
import BarcodeCore
import SharedKit

let arguments = CommandLine.arguments

func showHelp(command: String? = nil) {
    switch command {
    case "ocr":
        print("ocr — OCR 文字识别")
        print("")
        print("用法:")
        print("  snapglass-cli ocr file <path> [--engine vision|tesseract] [--lang <lang>]")
        print("  snapglass-cli ocr --file <path> [--engine vision|tesseract] [--languages <l1,l2>]")
        print("")
        print("选项:")
        print("  --engine      OCR 引擎 (vision 或 tesseract)，默认 vision")
        print("  --lang        识别语言代码（如 zh-Hans, en）")
        print("  --languages   逗号分隔的语言列表（如 zh-Hans,en）")
        print("")
        print("示例:")
        print("  snapglass-cli ocr file screenshot.png")
        print("  snapglass-cli ocr file photo.jpg --lang en")
        print("  snapglass-cli ocr --file scan.png --engine tesseract --languages zh-Hans,en")

    case "barcode":
        print("barcode — 条码/二维码识别")
        print("")
        print("用法:")
        print("  snapglass-cli barcode file <path>")
        print("  snapglass-cli barcode --file <path> [--types qr,code128,...]")
        print("")
        print("选项:")
        print("  --types  条码类型列表（逗号分隔），不指定则检测所有类型")
        print("")
        print("示例:")
        print("  snapglass-cli barcode file qrcode.png")
        print("  snapglass-cli barcode --file label.jpg --types qr,ean13")

    case "dev":
        print("dev — 开发者工具")
        print("")
        print("用法:")
        print("  snapglass-cli dev logs [--format json] [--output <path>]")
        print("  snapglass-cli dev compare <path> [--lang <lang>]")
        print("")
        print("子命令:")
        print("  logs         导出引擎对比日志")
        print("  compare      对比 Vision 和 Tesseract 引擎识别效果")
        print("")
        print("示例:")
        print("  snapglass-cli dev logs --format json")
        print("  snapglass-cli dev logs --output /tmp/dev-logs.json")
        print("  snapglass-cli dev compare screenshot.png --lang zh-Hans")

    case "capture":
        print("capture — 截图（尚未实现）")
        print("")
        print("用法:")
        print("  snapglass-cli capture --mode <area|window|fullscreen> [--output <path>]")

    case "history":
        print("history — 历史管理（尚未实现）")
        print("")
        print("用法:")
        print("  snapglass-cli history <list|search|delete|export|clear>")

    default:
        print("SnapGlass CLI — 命令行截图与 OCR 工具")
        print("")
        print("用法: snapglass-cli <command> [options]")
        print("")
        print("命令:")
        print("  ocr         OCR 文字识别（从图片提取文字）")
        print("  barcode     条码/二维码识别")
        print("  dev         开发者工具（引擎对比、日志导出）")
        print("  capture     截图（尚未实现）")
        print("  history     历史管理（尚未实现）")
        print("  preferences 偏好设置")
        print("")
        print("使用 snapglass-cli <command> --help 查看各命令详细用法")
    }
    print("")
}

func exitWithCode(_ code: ExitCode, _ message: String? = nil) -> Never {
    if let message {
        fputs("\(message)\n", stderr)
    }
    exit(code.rawValue)
}

if arguments.count <= 1 || arguments.contains("--help") {
    if arguments.count <= 1 {
        showHelp()
    } else if arguments.count > 1, arguments[1] == "--help" {
        showHelp()
    } else {
        let command = arguments[1]
        if command.hasPrefix("--") {
            showHelp()
        } else {
            showHelp(command: command)
        }
    }
    exit(0)
}

let cliArgs = Array(arguments.dropFirst())
let parser = CommandParser()
let handlers = CLIHandlers()

func execute(_ command: AutomationCommand, handlers: CLIHandlers) async throws -> AutomationResult {
    switch command {
    case .capture(let mode, let output):
        return try await handlers.handleCapture(mode: mode, output: output)
    case .ocr(let file, let engine, let languages, let devCompare, let outputFormat):
        return try await handlers.handleOCR(
            file: file, engine: engine, languages: languages,
            devCompare: devCompare, outputFormat: outputFormat
        )
    case .barcode(let file, let types, let outputFormat):
        return try await handlers.handleBarcode(
            file: file, types: types, outputFormat: outputFormat
        )
    case .history(let subcommand):
        return try await handlers.handleHistory(subcommand: subcommand)
    case .dev(let subcommand):
        return try await handlers.handleDev(subcommand: subcommand)
    case .preferences:
        return AutomationResult(success: true, output: "preferences 尚未实现")
    }
}

Task {
    do {
        let command = try parser.parse(cliArgs)
        let result = try await execute(command, handlers: handlers)
        if !result.output.isEmpty {
            print(result.output)
        }
        if let data = result.data, !data.isEmpty && result.output.isEmpty {
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        }
        exit(result.exitCode)
    } catch let error as AutomationError {
        fputs("错误: \(error.localizedDescription)\n", stderr)
        if case .invalidCommand = error {
            exit(ExitCode.argument.rawValue)
        } else if case .missingArgument = error {
            exit(ExitCode.argument.rawValue)
        } else if case .fileNotFound = error {
            exit(ExitCode.file.rawValue)
        } else if case .permissionDenied = error {
            exit(ExitCode.permission.rawValue)
        } else if case .engineError = error {
            exit(ExitCode.engine.rawValue)
        } else {
            exit(ExitCode.general.rawValue)
        }
    } catch {
        fputs("未知错误: \(error.localizedDescription)\n", stderr)
        exit(ExitCode.general.rawValue)
    }
}

RunLoop.main.run()
