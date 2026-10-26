import Foundation

/// 识别结果里可以直接展示、复制、打开的那份内容。
///
/// 与 `BarcodeCopyCandidate` 同域：视图层只负责摆放，判定「哪一条能复制、
/// 是不是链接」这类规则留在包里，由包测试直接覆盖。
public struct BarcodePayload: Sendable, Equatable {
    /// 内容类型，决定面板是否提供「打开链接」。
    public enum Kind: Sendable, Equatable {
        /// 可安全交给系统浏览器打开的 http/https 链接。
        case webLink(URL)
        /// 普通文本（包含 `mailto:` 等不应自动打开 scheme）。
        case text
    }

    /// 原始解码内容（已去掉首尾空白）。
    public let text: String
    /// 内容类型。
    public let kind: Kind
    /// 解出这条内容的符号学类型，用于面板徽标。
    public let type: BarcodeType

    public init(text: String, kind: Kind, type: BarcodeType) {
        self.text = text
        self.kind = kind
        self.type = type
    }

    /// 可打开的链接；非 http/https 内容为 `nil`。
    public var webLink: URL? {
        guard case .webLink(let url) = kind else { return nil }
        return url
    }

    /// 按内容分类一条原始 payload。
    public static func classify(_ text: String, type: BarcodeType) -> BarcodePayload {
        .init(text: text, kind: kind(of: text), type: type)
    }

    /// 判定 payload 是否是可打开的网页链接。
    ///
    /// 只有明确带 http/https scheme 且带 host 的内容才算链接；
    /// `mailto:`、`tel:`、任意自定义 scheme 一律按文本处理，避免一次误点
    /// 就把用户交给外部应用。
    public static func kind(of text: String) -> Kind {
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return .text }
        return .webLink(url)
    }
}

/// 把识别结果整理成面板可用的 payload 列表。
public enum BarcodePayloadFormatter {
    /// 过滤空白、去重并保持引擎顺序（置信度降序）。
    public static func payloads(from results: [BarcodeResult]) -> [BarcodePayload] {
        var seen = Set<String>()
        var payloads: [BarcodePayload] = []
        for result in results {
            let text = result.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            payloads.append(.classify(text, type: result.type))
        }
        return payloads
    }

    /// 复制用文本：所有 payload 按引擎顺序换行拼接。
    ///
    /// - Returns: 至少一条内容时返回拼接结果，否则 `nil`。
    public static func joinedText(from results: [BarcodeResult]) -> String? {
        let texts = payloads(from: results).map(\.text)
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n")
    }
}

extension BarcodeType {
    /// 面板徽标用的短名称（符号学名称，各语言一致）。
    public var displayName: String {
        switch self {
        case .qr: return "QR"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .ean8: return "EAN-8"
        case .ean13: return "EAN-13"
        case .pdf417: return "PDF417"
        case .aztec: return "Aztec"
        case .dataMatrix: return "Data Matrix"
        }
    }
}
