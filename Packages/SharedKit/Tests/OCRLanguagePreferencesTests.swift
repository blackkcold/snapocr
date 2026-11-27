import Foundation
import Testing

@testable import SharedKit

/// 验证中文优先默认值能真正落到已有用户身上。
///
/// Vision 在 `.accurate` 下用首位语言选模型，所以「存储顺序」是行为差异，不是
/// 外观差异。旧版本把英文排在首位写进每个开过偏好设置的用户域；不迁移就等于
/// 新默认只对新安装生效。
///
/// 偏好设置只有开关、没有重排 UI，所以存储数组的形态永远是「旧默认减去若干
/// 语言」。这里的用例覆盖真实形态，而不只是五元素全量。
struct OCRLanguagePreferencesTests {
    @Test func missingStoredOrderUsesTheChineseFirstDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(OCRLanguagePreferences.enabledLanguages(in: defaults) == ["zh-Hans", "en", "zh-Hant", "ja", "ko"])
        // 纯读路径不写回，避免把「没设置过」变成「设置过」。
        #expect(defaults.object(forKey: PreferenceKeys.ocrEnabledLanguages) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.ocrLanguageOrderMigrated) == nil)
    }

    /// 关键回归：本机用户域的真实形态 `(en, zh-Hans, zh-Hant)` 必须迁移。
    ///
    /// 关掉过日语或韩语的用户，存的就是这个三元素数组。旧的「与旧默认全等」
    /// 判据在这里不成立，于是 `en` 留在首位，中文截图继续落到拉丁模型上。
    @Test func shorterEnglishFirstOrderIsMigratedWithoutEnablingDisabledLanguages() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "zh-Hans", "zh-Hant"], forKey: PreferenceKeys.ocrEnabledLanguages)

        let languages = OCRLanguagePreferences.enabledLanguages(in: defaults)

        #expect(languages == ["zh-Hans", "en", "zh-Hant"])
        // 用户关掉的 ja/ko 不得被加回来。
        #expect(!languages.contains("ja"))
        #expect(!languages.contains("ko"))
        #expect(defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages) == languages)
        #expect(defaults.bool(forKey: PreferenceKeys.ocrLanguageOrderMigrated))
    }

    /// 精确的旧默认仍要处理，且启用集合完全保留（含 ja/ko）。
    @Test func fullLegacyDefaultIsReorderedWithEveryLanguageKept() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "zh-Hans", "zh-Hant", "ja", "ko"], forKey: PreferenceKeys.ocrEnabledLanguages)

        let languages = OCRLanguagePreferences.enabledLanguages(in: defaults)

        #expect(languages == ["zh-Hans", "en", "zh-Hant", "ja", "ko"])
        #expect(Set(languages) == ["en", "zh-Hans", "zh-Hant", "ja", "ko"])
    }

    /// 中文被关掉时不能把中文塞回去：集合与顺序都不变。
    ///
    /// 这条仍写迁移标记：这次判定已经对这份存储做过，之后重复判定只会让将来
    /// 修改本规则时悄悄改掉用户已选好的顺序。
    @Test func englishFirstOrderWithoutChineseIsLeftAlone() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "ja"], forKey: PreferenceKeys.ocrEnabledLanguages)

        let languages = OCRLanguagePreferences.enabledLanguages(in: defaults)

        #expect(languages == ["en", "ja"])
        #expect(defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages) == ["en", "ja"])
        #expect(defaults.bool(forKey: PreferenceKeys.ocrLanguageOrderMigrated))
    }

    /// 首位已经不是英文的数组一律不动：那些顺序只可能来自显式选择。
    @Test(arguments: [
        ["zh-Hans", "en"],
        ["ja", "en"],
        ["ko", "en", "zh-Hans"],
    ])
    func ordersThatDoNotStartWithEnglishAreNeverTouched(stored: [String]) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(stored, forKey: PreferenceKeys.ocrEnabledLanguages)

        #expect(OCRLanguagePreferences.enabledLanguages(in: defaults) == stored)
        #expect(defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages) == stored)
    }

    /// 迁移只发生一次：标记存在时，英文在首位也是用户之后的选择。
    @Test func migrationDoesNotRepeatAfterTheMarkerExists() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: PreferenceKeys.ocrLanguageOrderMigrated)
        defaults.set(["en", "zh-Hans"], forKey: PreferenceKeys.ocrEnabledLanguages)

        #expect(OCRLanguagePreferences.enabledLanguages(in: defaults) == ["en", "zh-Hans"])
        #expect(defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages) == ["en", "zh-Hans"])
    }

    /// 偏好设置里勾选语言属于用户自己的排列，写入后必须能扛住迁移。
    @Test func writingFromThePreferencesUIKeepsTheOrderOnTheNextRead() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "zh-Hans"], forKey: PreferenceKeys.ocrEnabledLanguages)
        OCRLanguagePreferences.setEnabledLanguages(["en", "zh-Hans"], in: defaults)

        #expect(OCRLanguagePreferences.enabledLanguages(in: defaults) == ["en", "zh-Hans"])
        #expect(defaults.bool(forKey: PreferenceKeys.ocrLanguageOrderMigrated))
    }

    @Test func emptyStoredOrderFallsBackToTheDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set([], forKey: PreferenceKeys.ocrEnabledLanguages)

        #expect(OCRLanguagePreferences.enabledLanguages(in: defaults) == PreferenceDefaults.ocrEnabledLanguages)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OCRLanguagePreferencesTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw OCRLanguagePreferencesTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private enum OCRLanguagePreferencesTestError: Error {
    case defaultsUnavailable
}
