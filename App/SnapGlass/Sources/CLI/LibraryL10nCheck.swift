import CoreText
import Foundation

/// Headless localization consistency and overflow check.
///
/// It validates key/placeholder parity, the approved library glossary and
/// width overflow for short UI labels. It cannot judge native tone; that stays
/// a human review step.
enum LibraryL10nCheck {
    private struct GlossaryEntry {
        let key: String
        let zhHans: String
        let japanese: String
        let korean: String
    }

    static func run(projectRoot: URL) throws -> String {
        let languages = ["en", "zh-Hans", "ja", "ko"]
        var tables: [String: [String: String]] = [:]
        for language in languages {
            tables[language] = try parseStrings(
                at:
                    projectRoot
                    .appendingPathComponent("App/SnapGlass/Resources", isDirectory: true)
                    .appendingPathComponent("\(language).lproj", isDirectory: true)
                    .appendingPathComponent("Localizable.strings")
            )
        }

        guard let english = tables["en"] else {
            throw L10nError.missingTable("en")
        }

        var failures: [String] = []
        var warnings: [String] = []

        checkKeyParity(
            languages: languages,
            english: english,
            tables: tables,
            failures: &failures,
            warnings: &warnings
        )
        checkGlossary(tables: tables, failures: &failures)
        checkShortLabelWidths(languages: languages, tables: tables, failures: &failures)

        let report: [String: Any] = [
            "ok": failures.isEmpty,
            "languages": languages,
            "keyCount": english.count,
            "failures": failures,
            "warnings": warnings,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    // MARK: - Checks

    private static func checkKeyParity(
        languages: [String],
        english: [String: String],
        tables: [String: [String: String]],
        failures: inout [String],
        warnings: inout [String]
    ) {
        for language in languages where language != "en" {
            guard let table = tables[language] else { continue }
            for key in Set(english.keys).subtracting(table.keys).sorted() {
                failures.append("\(language): missing key \(key)")
            }
            for key in Set(table.keys).subtracting(english.keys).sorted() {
                failures.append("\(language): extra key \(key)")
            }
            for (key, value) in table {
                guard let englishValue = english[key] else { continue }
                if placeholders(in: value) != placeholders(in: englishValue) {
                    failures.append("\(language): placeholder mismatch for \(key)")
                }
                if value == englishValue,
                    shortLabelKeys.contains(key),
                    !allowedIdenticalKeys.contains(key)
                {
                    warnings.append("\(language): value equals English for \(key)")
                }
            }
        }
    }

    private static func checkGlossary(
        tables: [String: [String: String]],
        failures: inout [String]
    ) {
        for entry in glossary {
            let values = [
                ("zh-Hans", entry.zhHans),
                ("ja", entry.japanese),
                ("ko", entry.korean),
            ]
            for (language, expected) in values {
                guard let actual = tables[language]?[entry.key] else { continue }
                if actual != expected {
                    failures.append(
                        "\(language): glossary mismatch for \(entry.key): \(actual) != \(expected)"
                    )
                }
            }
        }
    }

    private static func checkShortLabelWidths(
        languages: [String],
        tables: [String: [String: String]],
        failures: inout [String]
    ) {
        let font =
            CTFontCreateUIFontForLanguage(.system, 12, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for language in languages {
            guard let table = tables[language] else { continue }
            for key in shortLabelKeys {
                guard let value = table[key] else { continue }
                let width = textWidth(value, font: font)
                if width > 150 {
                    failures.append(
                        "\(language): label width \(Int(width))pt > 150pt for \(key)"
                    )
                }
            }
        }
    }

    // MARK: - Data

    private static let allowedIdenticalKeys: Set<String> = [
        "Live", "Audio", "Video", "Screenshots",
    ]

    private static let shortLabelKeys: Set<String> = [
        "Library", "All", "Favourites", "Screenshots", "Audio", "Video",
        "Colors", "Incomplete", "Recently Deleted", "Group", "Ungroup",
        "Export", "Merge", "Delete", "Cancel", "Save", "Tags", "Note",
        "Retry", "Done", "Select", "Favourite",
    ]

    private static let glossary: [GlossaryEntry] = [
        GlossaryEntry(key: "Library", zhHans: "资料库", japanese: "ライブラリ", korean: "라이브러리"),
        GlossaryEntry(key: "All", zhHans: "全部", japanese: "すべて", korean: "전체"),
        GlossaryEntry(key: "Favourites", zhHans: "收藏", japanese: "お気に入り", korean: "즐겨찾기"),
        GlossaryEntry(
            key: "Screenshots",
            zhHans: "截图",
            japanese: "スクリーンショット",
            korean: "스크린샷"
        ),
        GlossaryEntry(key: "Audio", zhHans: "音频", japanese: "音声", korean: "오디오"),
        GlossaryEntry(key: "Video", zhHans: "视频", japanese: "ビデオ", korean: "비디오"),
        GlossaryEntry(
            key: "Recently Deleted",
            zhHans: "最近删除",
            japanese: "最近削除した項目",
            korean: "최근 삭제된 항목"
        ),
        GlossaryEntry(key: "Incomplete", zhHans: "未完成", japanese: "未完了", korean: "미완료"),
        GlossaryEntry(key: "Group", zhHans: "归组", japanese: "グループ化", korean: "그룹화"),
        GlossaryEntry(key: "Ungroup", zhHans: "取消归组", japanese: "グループ解除", korean: "그룹 해제"),
        GlossaryEntry(key: "Merge", zhHans: "合并", japanese: "結合", korean: "병합"),
        GlossaryEntry(key: "Delete", zhHans: "删除", japanese: "削除", korean: "삭제"),
        GlossaryEntry(key: "Save", zhHans: "保存", japanese: "保存", korean: "저장"),
    ]

    // MARK: - Parsing and measurement

    private static func parseStrings(at url: URL) throws -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw L10nError.missingTable(url.lastPathComponent)
        }
        let pattern = #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                let keyRange = Range(match.range(at: 1), in: text),
                let valueRange = Range(match.range(at: 2), in: text)
            else { continue }
            result[unescape(String(text[keyRange]))] = unescape(String(text[valueRange]))
        }
        return result
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func placeholders(in value: String) -> [String] {
        let pattern = #"%[0-9]*[@dfs]"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return (regex?.matches(in: value, range: range) ?? [])
            .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
            .sorted()
    }

    private static func textWidth(_ value: String, font: CTFont) -> CGFloat {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, value as CFString, attributes) else {
            return 0
        }
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private enum L10nError: Error, LocalizedError {
        case missingTable(String)

        var errorDescription: String? {
            switch self {
            case .missingTable(let name): return "missing localization table: \(name)"
            }
        }
    }
}
