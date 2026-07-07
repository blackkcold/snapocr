import Foundation

// MARK: - URL 路由结果

/// URL Scheme 路由解析结果，包含解析后的自动化命令及附加标记。
public struct URLRouteResult: Sendable {
    /// 解析出的自动化命令
    public let command: AutomationCommand
    /// 截图后是否自动执行 OCR（仅 capture 命令时有效）
    public let ocrAfterCapture: Bool

    public init(command: AutomationCommand, ocrAfterCapture: Bool = false) {
        self.command = command
        self.ocrAfterCapture = ocrAfterCapture
    }
}

// MARK: - URL Scheme 路由器

/// SnapGlass URL Scheme 路由器。
///
/// 解析并路由 `snapglass://` 协议的 URL 到对应的 `AutomationCommand`。
/// 支持的 URL 格式：
///
/// | URL | 行为 |
/// |-----|------|
/// | `snapglass://capture?mode=area` | 区域截图 |
/// | `snapglass://capture?mode=area&ocr=1` | 区域截图后自动 OCR |
/// | `snapglass://capture?mode=fullscreen` | 全屏截图 |
/// | `snapglass://ocr?file=/path/to/image.png` | OCR 识别图片文字 |
/// | `snapglass://barcode?file=/path/to/image.png` | 扫描图片中的条码 |
public struct URLSchemeRouter: Sendable {
    private let scheme = "snapglass"

    public init() {}

    // MARK: - 路由分发

    /// 检查 URL 是否可被当前路由器处理。
    public func canHandle(_ url: URL) -> Bool {
        return url.scheme?.lowercased() == scheme
    }

    /// 解析 URL 并返回路由结果。
    ///
    /// - Parameter url: 完整的 `snapglass://` URL。
    /// - Returns: 包含解析出的命令及附加标记的 `URLRouteResult`。
    /// - Throws: `AutomationError.invalidCommand` 当 scheme/host 不支持或参数不合法时。
    public func route(_ url: URL) throws -> URLRouteResult {
        guard canHandle(url) else {
            throw AutomationError.invalidCommand(
                "不支持的 URL scheme: \(url.scheme ?? "nil")，需要 snapglass://"
            )
        }

        guard let host = url.host, !host.isEmpty else {
            throw AutomationError.invalidCommand("URL 缺少 host: \(url)")
        }

        let params = parseQueryParams(url)

        switch host.lowercased() {
        case "capture":
            let mode = params["mode"]
            let output = params["output"]
            let ocr = params["ocr"] == "1" || params["ocr"] == "true"
            let command = AutomationCommand.capture(mode: mode, output: output)
            return URLRouteResult(command: command, ocrAfterCapture: ocr)

        case "ocr":
            guard let file = params["file"], !file.isEmpty else {
                throw AutomationError.missingArgument("ocr 需要 file 参数（图片文件路径）")
            }
            let engine = params["engine"]
            let languages = params["languages"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let command = AutomationCommand.ocr(file: file, engine: engine, languages: languages)
            return URLRouteResult(command: command)

        case "barcode":
            guard let file = params["file"], !file.isEmpty else {
                throw AutomationError.missingArgument("barcode 需要 file 参数（图片文件路径）")
            }
            let types = params["types"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let command = AutomationCommand.barcode(file: file, types: types)
            return URLRouteResult(command: command)

        default:
            throw AutomationError.invalidCommand(
                "未知 URL host: \(host)，支持: capture, ocr, barcode"
            )
        }
    }

    // MARK: - 参数解析

    /// 解析 URL 查询参数为 `[String: String]` 字典。
    private func parseQueryParams(_ url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            return [:]
        }
        var params: [String: String] = [:]
        for item in items {
            params[item.name] = item.value
        }
        return params
    }
}
