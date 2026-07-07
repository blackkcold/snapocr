import SwiftUI
import AutomationCore
import CaptureCore
import OCRCore
import BarcodeCore

// MARK: - Routing View

/// URL Scheme 与 App Intents 的路由入口视图。
///
/// 负责:
/// - 处理 `snapglass://` 协议的 incoming URL
/// - 显示已注册的 URL Scheme 和 Shortcuts Actions
/// - 将路由命令分发到具体处理引擎（截图、OCR、条码）
struct RoutingView: View {
    @State private var routingCommand: String = ""
    @State private var routingStatus: RoutingStatus = .idle

    private let router = URLSchemeRouter()
    private let captureOrchestrator = CaptureOrchestrator()
    private let barcodeEngine = VisionBarcodeEngine()

    var body: some View {
        VStack {
            headerSection

            Divider()

            urlSchemeSection

            Divider()

            shortcutsSection

            Divider()

            statusSection
        }
        .padding()
        .onOpenURL { url in
            Task { await handleIncomingURL(url) }
        }
    }

    // MARK: - URL Handling

    @MainActor
    private func handleIncomingURL(_ url: URL) async {
        routingStatus = .processing
        routingCommand = url.absoluteString

        do {
            let routeResult = try router.route(url)
            let command = routeResult.command

            switch command {
            case .capture(let mode, _):
                let result = try await executeCapture(mode: mode)
                let message = "截图完成: \(result)"

                if routeResult.ocrAfterCapture, let outputPath = result.split(separator: "\n").last {
                    let path = String(outputPath.dropFirst("文件: ".count))
                    let ocrResult = try await executeOCR(file: path)
                    routingStatus = .completed("\(message)\nOCR: \(ocrResult)")
                } else {
                    routingStatus = .completed(message)
                }

            case .ocr(let file, _, _, _, _):
                let text = try await executeOCR(file: file)
                routingStatus = .completed("OCR 识别完成:\n\(text)")

            case .barcode(let file, _, _):
                let content = try await executeBarcode(file: file)
                routingStatus = .completed("条码扫描: \(content)")

            default:
                routingStatus = .completed("命令已接收: \(command)")
            }
        } catch {
            routingStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Command Execution

    private func executeCapture(mode: String?) async throws -> String {
        let captureMode: CaptureCore.CaptureMode = {
            switch mode {
            case "area": return .area(CGDisplayBounds(CGMainDisplayID()))
            case "window": return .window(nil)
            default: return .fullscreen
            }
        }()

        let result = try await captureOrchestrator.capture(
            mode: captureMode,
            options: CaptureOptions()
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-url-\(UUID().uuidString).png")
        try saveCGImage(result.image, to: tempURL)

        return "文件: \(tempURL.path)"
    }

    private func executeOCR(file: String) async throws -> String {
        let url = URL(fileURLWithPath: file)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RoutingError.fileNotFound(file)
        }

        let pipeline = OCRPipeline()
        let result = try await pipeline.recognize(image)
        return result.text
    }

    private func executeBarcode(file: String) async throws -> String {
        let url = URL(fileURLWithPath: file)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RoutingError.fileNotFound(file)
        }

        let results = try await barcodeEngine.detect(in: image, types: [])
        guard let first = results.first else {
            throw RoutingError.noBarcodeFound
        }

        if results.count > 1 {
            return results.map { "[\($0.type.rawValue)] \($0.payload)" }.joined(separator: "\n")
        }
        return "\(first.payload) (\(first.type.rawValue))"
    }

    private func saveCGImage(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else {
            throw RoutingError.saveFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RoutingError.saveFailed(url.path)
        }
    }
}

// MARK: - Subviews

extension RoutingView {

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("URL Scheme & App Intents")
                .font(.headline)
            Text("通过 URL Scheme 和 Shortcuts 自动化控制 SnapGlass")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var urlSchemeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Registered URL Schemes")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 4) {
                urlRow("snapglass://capture?mode=area")
                urlRow("snapglass://capture?mode=area&ocr=1")
                urlRow("snapglass://capture?mode=fullscreen")
                urlRow("snapglass://ocr?file=/path/to/image.png")
                urlRow("snapglass://barcode?file=/path/to/image.png")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func urlRow(_ url: String) -> some View {
        Text(url)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.blue)
            .lineLimit(1)
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available Shortcuts Actions")
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 6) {
                ShortcutRow(icon: "camera.viewfinder", title: "Capture Area", subtitle: "区域截图")
                ShortcutRow(icon: "rectangle.dashed", title: "Capture Fullscreen", subtitle: "全屏截图")
                ShortcutRow(icon: "text.viewfinder", title: "OCR Image", subtitle: "图片文字识别")
                ShortcutRow(icon: "qrcode", title: "Scan Barcode", subtitle: "扫描条码/二维码")
                ShortcutRow(icon: "magnifyingglass", title: "Search History", subtitle: "搜索截图历史")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Routing Status")
                .font(.subheadline)
                .fontWeight(.medium)

            switch routingStatus {
            case .idle:
                Text("等待 incoming URL...")
                    .font(.caption)
                    .foregroundColor(.secondary)

            case .processing:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("处理中: \(routingCommand)")
                        .font(.caption)
                }

            case .completed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundColor(.green)

            case .error(let detail):
                Text("错误: \(detail)")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Supporting Types

struct ShortcutRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

enum RoutingStatus: Equatable {
    case idle
    case processing
    case completed(String)
    case error(String)
}

enum RoutingError: Error, LocalizedError {
    case fileNotFound(String)
    case noBarcodeFound
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "文件未找到: \(path)"
        case .noBarcodeFound: return "未在图片中检测到条码"
        case .saveFailed(let path): return "截图保存失败: \(path)"
        }
    }
}

// MARK: - String Helper

extension String {
    func removingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
