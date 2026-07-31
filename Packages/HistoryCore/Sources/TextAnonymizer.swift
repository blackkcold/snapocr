import Foundation

/// 脱敏级别
///
/// 控制文本中敏感信息的替换程度。
public enum AnonymizationLevel: String, Sendable, Codable, CaseIterable {
    /// 不做任何脱敏
    case none
    /// 部分脱敏: 保留首尾字符，中间用 `*` 替换
    case partial
    /// 完全脱敏: 整个敏感信息替换为 `***`
    case full
}

/// 文本脱敏器
///
/// 使用正则表达式识别和替换 OCR 文本中的敏感信息，支持多种脱敏级别。
/// 用于历史导出功能中对隐私数据的保护。
///
/// ## 支持的敏感信息类型
///
/// | 类型 | 正则模式 | 示例 |
/// |------|---------|------|
/// | 中国大陆手机号 | `1[3-9]\d{9}` | 138****5678 |
/// | 中国大陆身份证号 | `\d{17}[\dXx]` | 110101********1234 |
/// | 邮箱地址 | `[\w.\-+]+@[\w.\-]+\.\w+` | u***@e***.com |
/// | 银行卡号 | `\d{16,19}` | ****1234 |
/// | 固定电话 | `\d{3,4}-\d{7,8}` | 010-****5678 |
///
/// ## 使用示例
///
/// ```swift
/// let anonymizer = TextAnonymizer()
/// let result = anonymizer.anonymize(
///     "请联系 13812345678 或 email@example.com",
///     level: .partial
/// )
/// // 结果: "请联系 138****5678 或 e***@e***.com"
/// ```
public struct TextAnonymizer: Sendable {

    // MARK: - 正则表达式模式

    /// 中国大陆手机号: 1[3-9]XXXXXXXXX
    private static let phonePattern = "1[3-9]\\d{9}"

    /// 中国大陆身份证号: 6位地区 + 8位生日 + 3位顺序 + 1位校验
    private static let idCardPattern = "\\d{17}[\\dXx]"

    /// 邮箱地址
    private static let emailPattern = "[\\w.\\-+]+@[\\w.\\-]+\\.\\w+"

    /// 银行卡号 (16-19位数字)
    private static let bankCardPattern = "\\d{16,19}"

    /// 固定电话 (区号-号码)
    private static let landlinePattern = "\\d{3,4}-\\d{7,8}"

/// 敏感数据类型
private enum SensitiveDataType: Sendable, CaseIterable {
    case phone
    case idCard
    case email
    case bankCard
    case landline
}

    // MARK: - Properties

    /// 预编译的正则表达式与对应的敏感数据类型
    private let patterns: [(NSRegularExpression, SensitiveDataType)]

    // MARK: - Initialization

    /// 创建文本脱敏器
    ///
    /// 初始化时预编译所有敏感信息匹配模式。
    public init() {
        var compiled: [(NSRegularExpression, SensitiveDataType)] = []

        // Match longer, more specific numeric identifiers before phone numbers to
        // avoid masking an embedded phone-like substring inside an ID/card number.
        if let regex = try? NSRegularExpression(
            pattern: Self.idCardPattern, options: []
        ) {
            compiled.append((regex, .idCard))
        }

        if let regex = try? NSRegularExpression(
            pattern: Self.emailPattern, options: [.caseInsensitive]
        ) {
            compiled.append((regex, .email))
        }

        if let regex = try? NSRegularExpression(
            pattern: Self.bankCardPattern, options: []
        ) {
            compiled.append((regex, .bankCard))
        }

        if let regex = try? NSRegularExpression(
            pattern: Self.landlinePattern, options: []
        ) {
            compiled.append((regex, .landline))
        }

        if let regex = try? NSRegularExpression(
            pattern: Self.phonePattern, options: []
        ) {
            compiled.append((regex, .phone))
        }

        self.patterns = compiled
    }

    // MARK: - Public API

    /// 对文本进行脱敏处理
    ///
    /// 根据指定的脱敏级别，替换文本中识别到的所有敏感信息。
    ///
    /// - Parameters:
    ///   - text: 待脱敏的原始文本
    ///   - level: 脱敏级别，默认 `.partial`
    /// - Returns: 脱敏后的文本
    public func anonymize(_ text: String, level: AnonymizationLevel = .partial) -> String {
        guard level != .none else { return text }

        var result = text

        for (regex, dataType) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result) else {
                    continue
                }
                let matchedString = String(result[matchRange])
                let replacement: String
                switch dataType {
                case .phone:
                    replacement = Self.anonymizePhone(matchedString, level: level)
                case .idCard:
                    replacement = Self.anonymizeIDCard(matchedString, level: level)
                case .email:
                    replacement = Self.anonymizeEmail(matchedString, level: level)
                case .bankCard:
                    replacement = Self.anonymizeBankCard(matchedString, level: level)
                case .landline:
                    replacement = Self.anonymizeLandline(matchedString, level: level)
                }
                result.replaceSubrange(matchRange, with: replacement)
            }
        }

        return result
    }

    /// 对多条历史条目的文本进行批量脱敏
    ///
    /// 返回新的条目数组。文本、窗口元数据和标签会被脱敏，本地文件路径不会导出。
    ///
    /// - Parameters:
    ///   - entries: 原始历史条目数组
    ///   - level: 脱敏级别
    /// - Returns: 脱敏后的条目数组
    public func anonymizeEntries(
        _ entries: [HistoryEntry],
        level: AnonymizationLevel
    ) -> [HistoryEntry] {
        guard level != .none else { return entries }

        return entries.map { entry in
            return HistoryEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                textContent: anonymize(entry.textContent, level: level),
                ocrConfidence: entry.ocrConfidence,
                captureMode: entry.captureMode,
                sourceType: entry.sourceType,
                sourceAppName: entry.sourceAppName.map { anonymize($0, level: level) },
                sourceWindowTitle: entry.sourceWindowTitle.map { anonymize($0, level: level) },
                imagePath: nil,
                thumbnailPath: nil,
                isFavourite: entry.isFavourite,
                tags: entry.tags.map { anonymize($0, level: level) }
            )
        }
    }

    /// 检测文本是否包含敏感信息
    ///
    /// 快速扫描文本，判断是否存在需要脱敏的内容。
    ///
    /// - Parameter text: 待检测文本
    /// - Returns: 如包含任意敏感信息返回 `true`
    public func containsSensitiveInfo(_ text: String) -> Bool {
        for (regex, _) in patterns {
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - 脱敏处理函数

    /// 手机号脱敏: 138****5678 (partial) 或 *** (full)
    private static func anonymizePhone(_ match: String, level: AnonymizationLevel) -> String {
        switch level {
        case .none:
            return match
        case .partial:
            guard match.count == 11 else { return String(repeating: "*", count: match.count) }
            let prefix = String(match.prefix(3))
            let suffix = String(match.suffix(4))
            return "\(prefix)****\(suffix)"
        case .full:
            return "***"
        }
    }

    /// 身份证号脱敏: 110101********1234 (partial) 或 *** (full)
    private static func anonymizeIDCard(_ match: String, level: AnonymizationLevel) -> String {
        switch level {
        case .none:
            return match
        case .partial:
            guard match.count == 18 else { return String(repeating: "*", count: match.count) }
            let prefix = String(match.prefix(6))
            let suffix = String(match.suffix(4))
            return "\(prefix)********\(suffix)"
        case .full:
            return "***"
        }
    }

    /// 邮箱脱敏: u***@e***.com (partial) 或 ***@***.*** (full)
    private static func anonymizeEmail(_ match: String, level: AnonymizationLevel) -> String {
        switch level {
        case .none:
            return match
        case .partial:
            let parts = match.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(repeating: "*", count: match.count) }
            let username = String(parts[0])
            let domainPart = String(parts[1])

            let maskedUser: String
            maskedUser = String(username.prefix(1)) + "***"

            let domainComponents = domainPart.split(separator: ".", omittingEmptySubsequences: false)
            var maskedDomains: [String] = []
            for (i, comp) in domainComponents.enumerated() {
                let compStr = String(comp)
                if i == 0 {
                    maskedDomains.append(String(compStr.prefix(1)) + "***")
                } else {
                    maskedDomains.append(compStr)
                }
            }

            return "\(maskedUser)@\(maskedDomains.joined(separator: "."))"
        case .full:
            return "***@***.***"
        }
    }

    /// 银行卡号脱敏: 保留后4位 (partial) 或 *** (full)
    private static func anonymizeBankCard(_ match: String, level: AnonymizationLevel) -> String {
        switch level {
        case .none:
            return match
        case .partial:
            guard match.count >= 4 else { return String(repeating: "*", count: match.count) }
            let visible = String(match.suffix(4))
            let masked = String(repeating: "*", count: match.count - 4)
            return masked + visible
        case .full:
            return "***"
        }
    }

    /// 固定电话脱敏: 010-****5678 (partial) 或 *** (full)
    private static func anonymizeLandline(_ match: String, level: AnonymizationLevel) -> String {
        switch level {
        case .none:
            return match
        case .partial:
            let parts = match.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return String(repeating: "*", count: match.count) }
            let areaCode = String(parts[0])
            let number = String(parts[1])
            guard number.count >= 4 else { return areaCode + "-" + String(repeating: "*", count: number.count) }
            let maskCount = number.count - 4
            let visible = String(number.suffix(4))
            let masked = String(repeating: "*", count: max(0, maskCount))
            return "\(areaCode)-\(masked)\(visible)"
        case .full:
            return "***"
        }
    }
}
