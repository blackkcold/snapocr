import Foundation
import Testing

@testable import SharedKit

/// 验证中文优先默认值能真正落到已有用户身上。
///
/// Vision 在 `.accurate` 下用首位语言选模型，所以「存储顺序」是行为差异，不是
/// 外观差异。旧版本把 `(en, zh-Hans, zh-Hant, ja, ko)` 写进每个开过偏好设置的
/// 用户域；不迁移就等于新默认只对新安装生效。
struct OCRLanguagePreferencesTests {
    @Test func missingStoredOrderUsesTheChineseFirstDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(OCRLanguagePreferences.enabledLanguages(in: defaults) == ["zh-Hans", "en", "zh-Hant", "ja", "ko"])
        // 纯读路径不写回，避免把「没设置过」变成「设置过」。
        #expect(defaults.object(forKey: PreferenceKeys.ocrEnabledLanguages) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.ocrLanguageOrderMigrated) == nil)
    }

    /// 关键回归：存储值正好等于旧默认时视为未设置，让中文优先生效。
    @Test func legacyEnglishFirstDefaultIsMigratedToChineseFirst() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "zh-Hans", "zh-Hant", "ja", "ko"], forKey: PreferenceKeys.ocrEnabledLanguages)

        let languages = OCRLanguagePreferences.enabledLanguages(in: defaults)

        #expect(languages == PreferenceDefaults.ocrEnabledLanguages)
        #expect(languages.first == "zh-Hans")
        // 迁移结果写回，偏好设置界面与后续读取看到同一个顺序。
        #expect(defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages) == languages)
        #expect(defaults.bool(forKey: PreferenceKeys.ocrLanguageOrderMigrated))
    }

    /// 用户自己排过的顺序必须保留，哪怕只是调整了旧默认里的一项。
    @Test func userChosenOrderSurvivesTheMigration() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["ja", "en", "zh-Hans"], forKey: PreferenceKeys.ocrEnabledLanguages)

        let languages = OCRLanguagePreferences.enabledLanguages(in: defaults)

        #expect(languages == ["ja", "en", "zh-Hans"])
        #expect(defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages) == ["ja", "en", "zh-Hans"])
        #expect(defaults.object(forKey: PreferenceKeys.ocrLanguageOrderMigrated) == nil)
    }

    /// 迁移只发生一次：之后用户再把顺序调回英文优先，就是他的选择，不该被改回。
    @Test func theMigrationDoesNotRepeatAfterTheUserRestoresEnglishFirst() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(OCRLanguagePreferences.legacyDefaultLanguages, forKey: PreferenceKeys.ocrEnabledLanguages)
        #expect(OCRLanguagePreferences.enabledLanguages(in: defaults).first == "zh-Hans")

        defaults.set(OCRLanguagePreferences.legacyDefaultLanguages, forKey: PreferenceKeys.ocrEnabledLanguages)

        #expect(
            OCRLanguagePreferences.enabledLanguages(in: defaults)
                == OCRLanguagePreferences.legacyDefaultLanguages
        )
    }

    /// 偏好设置里勾选语言属于用户自己的排列，写入后必须能扛住迁移。
    @Test func writingFromThePreferencesUIKeepsTheOrderOnTheNextRead() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(OCRLanguagePreferences.legacyDefaultLanguages, forKey: PreferenceKeys.ocrEnabledLanguages)
        OCRLanguagePreferences.setEnabledLanguages(OCRLanguagePreferences.legacyDefaultLanguages, in: defaults)

        #expect(
            OCRLanguagePreferences.enabledLanguages(in: defaults)
                == OCRLanguagePreferences.legacyDefaultLanguages
        )
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
