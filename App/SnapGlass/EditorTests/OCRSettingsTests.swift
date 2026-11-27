import Foundation
import SharedKit
import Testing

@testable import EditorInteractionTests

/// 验证偏好设置到 `OCROptions` 的接线：中文优先必须真的到达 Vision。
///
/// `OCRSettings` 是抓屏与编辑器共用的唯一入口，所以这条同时覆盖两条生产路径。
struct OCRSettingsTests {
    /// 关键回归：已装用户存储的语言顺序仍是旧的英文优先默认时，必须迁移成中文优先。
    ///
    /// Vision 在 `.accurate` 下用首个语言选模型：`en-US` 排第一会让中文截图落到
    /// 拉丁模型上，这正是本 PR 要修的原始问题。旧版本把这个数组写进每个开过
    /// 偏好设置的用户域，所以「只改默认常量」到不了他们身上。
    @Test func storedEnglishFirstOrderIsMigratedToChineseFirst() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "zh-Hans", "zh-Hant", "ja", "ko"], forKey: PreferenceKeys.ocrEnabledLanguages)
        defaults.set("auto", forKey: PreferenceKeys.ocrLanguagePriority)

        let options = OCRSettings.current(defaults: defaults)

        #expect(options.languages.first == "zh-Hans")
        #expect(options.languages == ["zh-Hans", "en-US", "zh-Hant", "ja-JP", "ko-KR"])
        #expect(options.recognitionLevel == .accurate)
    }

    /// 关键回归：本机用户域的真实形态 `(en, zh-Hans, zh-Hant)` + `auto` 必须迁移成中文优先。
    ///
    /// 偏好设置只有开关没有重排，用户关掉日语/韩语后存的就是这个三元素数组。
    /// 只按「与旧默认全等」判定的迁移到不了这批人身上，`en-US` 会继续排在首位。
    @Test func shorterStoredEnglishFirstOrderIsMigratedToChineseFirst() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "zh-Hans", "zh-Hant"], forKey: PreferenceKeys.ocrEnabledLanguages)
        defaults.set("auto", forKey: PreferenceKeys.ocrLanguagePriority)

        let options = OCRSettings.current(defaults: defaults)

        #expect(options.languages.first == "zh-Hans")
        #expect(options.languages == ["zh-Hans", "en-US", "zh-Hant"])
        #expect(options.recognitionLevel == .accurate)
    }

    /// 本机的完整组合（三元素 + `zh` 优先级）也必须以中文开头，且不引入已关闭的语言。
    @Test func realStoredDomainShapeWithChinesePriorityKeepsChineseFirst() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["en", "zh-Hans", "zh-Hant"], forKey: PreferenceKeys.ocrEnabledLanguages)
        defaults.set("zh", forKey: PreferenceKeys.ocrLanguagePriority)

        let options = OCRSettings.current(defaults: defaults)

        #expect(options.languages.first == "zh-Hans")
        #expect(options.languages == ["zh-Hans", "en-US", "zh-Hant"])
    }

    /// 用户自己排过的顺序必须原样到达 Vision。
    @Test func userChosenOrderReachesTheEngine() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["ja", "en", "zh-Hans"], forKey: PreferenceKeys.ocrEnabledLanguages)

        let options = OCRSettings.current(defaults: defaults)

        #expect(options.languages == ["ja-JP", "en-US", "zh-Hans"])
    }

    /// 显式选了「English First」时，优先级语言仍然被提到最前。
    @Test func explicitPriorityStillLeads() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["zh-Hans", "en", "ja"], forKey: PreferenceKeys.ocrEnabledLanguages)
        defaults.set("ja", forKey: PreferenceKeys.ocrLanguagePriority)

        let options = OCRSettings.current(defaults: defaults)

        #expect(options.languages == ["ja-JP", "zh-Hans", "en-US"])
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "OCRSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw OCRSettingsTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private enum OCRSettingsTestError: Error {
    case defaultsUnavailable
}
