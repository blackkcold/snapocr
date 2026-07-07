import CoreGraphics
import Foundation
import ImageIO
import OCRCore
import BarcodeCore
import SharedKit

public struct CLIHandlers: Sendable {

    private let logger: Logger

    public init() {
        self.logger = Logger(category: "cli-handlers")
    }

    // MARK: - 截图

    public func handleCapture(mode: String?, output: String?) async throws -> AutomationResult {
        let modeLabel = mode ?? "area"
        logger.info("截图请求 | 模式: \(modeLabel)")
        return AutomationResult(
            success: true,
            output: "截图功能尚未实现（模式: \(modeLabel)）"
        )
    }

    // MARK: - OCR

    public func handleOCR(
        file: String,
        engine: String?,
        languages: [String]?,
        devCompare: Bool = false,
        outputFormat: String? = nil
    ) async throws -> AutomationResult {
        let cgImage = try loadImage(from: file)

        let langs = languages ?? ["zh-Hans", "en"]

        // 开发者模式：同时运行两个引擎并输出对比
        if devCompare {
            return try await handleDevCompare(file: file, languages: langs)
        }

        let engineType: OCREngineType = resolveEngine(engine)
        let options = OCROptions(languages: langs, engineSelection: engineType)

        let pipeline = OCRPipeline(options: options)
        let result: OCRResult
        do {
            result = try await pipeline.recognize(cgImage)
        } catch let error as OCRError {
            return AutomationResult(
                success: false,
                output: "OCR 识别失败: \(error.localizedDescription)",
                exitCode: .engine
            )
        } catch {
            return AutomationResult(
                success: false,
                output: "OCR 未知错误: \(error.localizedDescription)",
                exitCode: .engine
            )
        }

        if outputFormat?.lowercased() == "json" {
            return formatOCRResultAsJSON(result)
        }

        let output = formatOCRResult(result)
        return AutomationResult(success: true, output: output, exitCode: .success)
    }

    // MARK: - 条码

    public func handleBarcode(
        file: String,
        types: [String]?,
        outputFormat: String? = nil
    ) async throws -> AutomationResult {
        let cgImage = try loadImage(from: file)

        let barcodeTypes: [BarcodeType] = types?.compactMap { BarcodeType(rawValue: $0.lowercased()) } ?? []
        let engine = VisionBarcodeEngine()

        let results: [BarcodeResult]
        do {
            results = try await engine.detect(in: cgImage, types: barcodeTypes)
        } catch let error as BarcodeError {
            return AutomationResult(
                success: false,
                output: "条码识别失败: \(error.localizedDescription)",
                exitCode: .engine
            )
        } catch {
            return AutomationResult(
                success: false,
                output: "条码未知错误: \(error.localizedDescription)",
                exitCode: .engine
            )
        }

        if results.isEmpty {
            return AutomationResult(
                success: false,
                output: "未检测到条码",
                exitCode: .general
            )
        }

        if outputFormat?.lowercased() == "json" {
            return formatBarcodeResultsAsJSON(results)
        }

        let output = formatBarcodeResults(results)
        return AutomationResult(success: true, output: output, exitCode: .success)
    }

    // MARK: - 历史

    public func handleHistory(subcommand: AutomationCommand.HistorySubcommand) async throws -> AutomationResult {
        logger.info("历史管理 | 子命令: \(subcommand.rawValue)")
        return AutomationResult(
            success: true,
            output: "历史管理功能尚未实现（子命令: \(subcommand.rawValue)）"
        )
    }

    // MARK: - 开发者模式

    public func handleDev(subcommand: AutomationCommand.DevSubcommand) async throws -> AutomationResult {
        switch subcommand {
        case .logs(let format, let output):
            return try await handleDevLogs(format: format, output: output)
        case .compare(let file, let languages):
            return try await handleDevCompare(file: file, languages: languages)
        }
    }

    private func handleDevLogs(format: String?, output: String?) async throws -> AutomationResult {
        let devService = DevModeService.shared
        let jsonData = await devService.exportLogs()

        if jsonData.isEmpty {
            return AutomationResult(
                success: true,
                output: "[]",
                data: "[]".data(using: .utf8),
                exitCode: .success
            )
        }

        let formatter = format?.lowercased() ?? "json"
        let outputStr: String
        switch formatter {
        case "json":
            outputStr = String(data: jsonData, encoding: .utf8) ?? "[]"
        default:
            outputStr = String(data: jsonData, encoding: .utf8) ?? "[]"
        }

        if let outputPath = output {
            let url = URL(fileURLWithPath: outputPath)
            do {
                try jsonData.write(to: url, options: .atomic)
                return AutomationResult(
                    success: true,
                    output: "日志已导出到: \(outputPath) (\(jsonData.count) bytes)",
                    exitCode: .success
                )
            } catch {
                return AutomationResult(
                    success: false,
                    output: "无法写入文件: \(outputPath) - \(error.localizedDescription)",
                    exitCode: .file
                )
            }
        }

        return AutomationResult(
            success: true,
            output: outputStr,
            data: jsonData,
            exitCode: .success
        )
    }

    private func handleDevCompare(file: String, languages: [String]?) async throws -> AutomationResult {
        let cgImage = try loadImage(from: file)
        let langs = languages ?? ["zh-Hans", "en"]

        let devService = DevModeService.shared
        let compareResult = await devService.compareEngines(image: cgImage, languages: langs)

        var output = "=== 引擎对比结果 ===\n\n"
        output += "Vision 引擎:\n"
        output += "  文本: \(compareResult.vision.text.prefix(200))\n"
        output += "  置信度: \(String(format: "%.4f", compareResult.vision.confidence))\n"
        output += "  耗时: \(String(format: "%.1f", compareResult.vision.processingTimeMs))ms\n\n"
        output += "Tesseract 引擎:\n"
        output += "  文本: \(compareResult.tesseract.text.prefix(200))\n"
        output += "  置信度: \(String(format: "%.4f", compareResult.tesseract.confidence))\n"
        output += "  耗时: \(String(format: "%.1f", compareResult.tesseract.processingTimeMs))ms\n\n"
        output += "对比分析:\n"
        output += "  文本一致: \(compareResult.isTextMatch ? "是" : "否")\n"
        output += "  置信度差: \(String(format: "%.4f", compareResult.confidenceDelta))\n"
        output += "  耗时差: \(String(format: "%.1f", compareResult.timeDelta))ms\n"
        output += "  较优引擎: \(compareResult.betterEngine)\n"

        return AutomationResult(success: true, output: output, exitCode: .success)
    }

    // MARK: - 图片加载

    private func loadImage(from path: String) throws -> CGImage {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw AutomationError.fileNotFound(path)
        }
        guard fileManager.isReadableFile(atPath: path) else {
            throw AutomationError.permissionDenied
        }
        let url = URL(fileURLWithPath: path)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw AutomationError.fileNotFound("无法读取图片: \(path)（格式不支持或文件损坏）")
        }
        return cgImage
    }

    // MARK: - 引擎解析

    private func resolveEngine(_ engine: String?) -> OCREngineType {
        switch engine?.lowercased() {
        case "tesseract":
            return .tesseract(languageDataPath: nil)
        default:
            return .vision
        }
    }

    // MARK: - 格式化

    private func formatOCRResult(_ result: OCRResult) -> String {
        var lines: [String] = []
        lines.append(result.text)
        lines.append("")
        lines.append("---")
        lines.append("引擎: \(engineLabel(result.engineType))")
        lines.append("置信度: \(String(format: "%.2f", result.confidence))")
        lines.append("耗时: \(String(format: "%.1f", result.processingTimeMs))ms")
        lines.append("文本行数: \(result.observations.count)")
        lines.append("布局保留: \(result.layoutPreserved ? "是" : "否")")
        return lines.joined(separator: "\n")
    }

    private func formatBarcodeResults(_ results: [BarcodeResult]) -> String {
        guard !results.isEmpty else { return "未检测到条码" }
        var lines: [String] = ["检测到 \(results.count) 个条码:", ""]
        for (index, barcode) in results.enumerated() {
            lines.append("--- 条码 \(index + 1) ---")
            lines.append("类型: \(barcode.type.rawValue.uppercased())")
            lines.append("内容: \(barcode.payload)")
            lines.append("置信度: \(String(format: "%.2f", barcode.confidence))")
            lines.append("位置: (\(String(format: "%.3f", barcode.boundingBox.origin.x)), \(String(format: "%.3f", barcode.boundingBox.origin.y)), \(String(format: "%.3f", barcode.boundingBox.size.width))x\(String(format: "%.3f", barcode.boundingBox.size.height)))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func engineLabel(_ engine: OCREngineType) -> String {
        switch engine {
        case .vision: return "Vision"
        case .tesseract: return "Tesseract"
        case .windowsMediaOcr: return "WindowsMediaOCR"
        }
    }

    // MARK: - JSON 格式化

    /// 将 OCR 结果格式化为 JSON 输出。
    private func formatOCRResultAsJSON(_ result: OCRResult) -> AutomationResult {
        let dict: [String: Any] = [
            "success": true,
            "text": result.text,
            "confidence": result.confidence,
            "engine": engineLabel(result.engineType),
            "processingTimeMs": result.processingTimeMs,
            "layoutPreserved": result.layoutPreserved,
            "lineCount": result.observations.count,
            "lines": result.observations.map { line in
                [
                    "text": line.text,
                    "confidence": line.confidence,
                    "box": [
                        "x": line.boundingBox.origin.x,
                        "y": line.boundingBox.origin.y,
                        "width": line.boundingBox.size.width,
                        "height": line.boundingBox.size.height,
                    ],
                ]
            },
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return AutomationResult(success: false, output: "JSON 序列化失败", exitCode: .general)
        }
        return AutomationResult(success: true, output: jsonString, data: jsonData, exitCode: .success)
    }

    /// 将条码结果格式化为 JSON 输出。
    private func formatBarcodeResultsAsJSON(_ results: [BarcodeResult]) -> AutomationResult {
        let dict: [String: Any] = [
            "success": true,
            "count": results.count,
            "barcodes": results.map { barcode in
                [
                    "payload": barcode.payload,
                    "type": barcode.type.rawValue,
                    "confidence": barcode.confidence,
                    "box": [
                        "x": barcode.boundingBox.origin.x,
                        "y": barcode.boundingBox.origin.y,
                        "width": barcode.boundingBox.size.width,
                        "height": barcode.boundingBox.size.height,
                    ],
                ]
            },
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return AutomationResult(success: false, output: "JSON 序列化失败", exitCode: .general)
        }
        return AutomationResult(success: true, output: jsonString, data: jsonData, exitCode: .success)
    }
}