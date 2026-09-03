import Foundation

// MARK: - Tesseract Language Support

/// Tesseract 引擎语言代码工具。
///
/// 提供 Vision 框架语言代码与 Tesseract 语言代码之间的双向映射，
/// 以及语言包可用性检查。
///
/// 语言映射关系（Vision → Tesseract）:
/// - `en` / `en-US` / `en-GB` → `eng`
/// - `zh-Hans` → `chi_sim`
/// - `zh-Hant` → `chi_tra`
/// - `ja` / `ja-JP` → `jpn`
/// - `ko` / `ko-KR` → `kor`
/// - `fr` / `fr-FR` → `fra`
/// - `de` / `de-DE` → `deu`
/// - `es` / `es-ES` → `spa`
/// - `pt` / `pt-PT` → `por`
/// - `it` / `it-IT` → `ita`
enum TesseractLanguageSupport: Sendable {
    /// Vision 框架语言代码到 Tesseract 语言代码的映射表。
    static let visionToTesseract: [String: String] = [
        "en": "eng",
        "en-US": "eng",
        "en-GB": "eng",
        "zh-Hans": "chi_sim",
        "zh-Hant": "chi_tra",
        "ja": "jpn",
        "ja-JP": "jpn",
        "ko": "kor",
        "ko-KR": "kor",
        "fr": "fra",
        "fr-FR": "fra",
        "de": "deu",
        "de-DE": "deu",
        "es": "spa",
        "es-ES": "spa",
        "pt": "por",
        "pt-PT": "por",
        "it": "ita",
        "it-IT": "ita",
    ]

    /// Tesseract 语言代码到本地化展示名称的映射。
    static let displayNames: [String: String] = [
        "eng": "English",
        "chi_sim": "简体中文",
        "chi_tra": "繁體中文",
        "jpn": "日本語",
        "kor": "한국어",
        "fra": "Français",
        "deu": "Deutsch",
        "spa": "Español",
        "por": "Português",
        "ita": "Italiano",
    ]

    /// 所有支持的 Tesseract 语言代码集合。
    ///
    /// 包含设计文档中列出的 10 种语言:
    /// eng, chi_sim, chi_tra, jpn, kor, fra, deu, spa, por, ita。
    static let supportedTesseractLanguages: Set<String> = [
        "eng", "chi_sim", "chi_tra", "jpn", "kor",
        "fra", "deu", "spa", "por", "ita",
    ]

    /// 将 Vision 框架语言代码转换为 Tesseract 语言代码。
    ///
    /// - Parameter visionCode: Vision 框架语言代码（如 `"zh-Hans"`, `"en-US"`）。
    /// - Returns: 对应的 Tesseract 语言代码（如 `"chi_sim"`, `"eng"`）。
    ///   如果未找到映射，返回原代码。
    static func tesseractCode(for visionCode: String) -> String {
        // 尝试精确匹配
        if let code = visionToTesseract[visionCode] {
            return code
        }
        // 尝试短代码前缀匹配（如 "zh" → 取第一个匹配 "zh-Hans" 对应 "chi_sim"）
        let shortCode = String(visionCode.prefix(2))
        for (key, value) in visionToTesseract where key.hasPrefix(shortCode) {
            return value
        }
        return visionCode
    }

    /// 将多个 Vision 语言代码批量转换为 Tesseract 语言代码。
    ///
    /// - Parameter visionCodes: Vision 语言代码数组。
    /// - Returns: 去重后的 Tesseract 语言代码数组。
    static func tesseractCodes(for visionCodes: [String]) -> [String] {
        let codes = visionCodes.map { tesseractCode(for: $0) }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    /// 获取 Tesseract 语言代码的展示名称。
    ///
    /// - Parameter tesseractCode: Tesseract 语言代码（如 `"chi_sim"`）。
    /// - Returns: 本地化展示名称（如 `"简体中文"`）。
    static func displayName(for tesseractCode: String) -> String {
        displayNames[tesseractCode] ?? tesseractCode
    }
}
