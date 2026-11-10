import Foundation
import SharedKit
import Testing

struct AppLocalizationTests {
    @Test func resolvesEveryExplicitAppLanguageLocale() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let languages: [(rawValue: String, localeIdentifier: String)] = [
            ("english", "en"),
            ("simplifiedChinese", "zh-Hans"),
            ("japanese", "ja"),
            ("korean", "ko"),
        ]

        for language in languages {
            defaults.set(language.rawValue, forKey: PreferenceKeys.appLanguage)
            #expect(AppLocalization.locale(in: defaults).identifier == language.localeIdentifier)
        }
    }

    @Test func usesCurrentLocaleForMissingSystemAndInvalidPreferences() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let currentIdentifier = Locale.current.identifier
        #expect(AppLocalization.locale(in: defaults).identifier == currentIdentifier)

        for preference in ["system", "invalid-language"] {
            defaults.set(preference, forKey: PreferenceKeys.appLanguage)
            #expect(AppLocalization.locale(in: defaults).identifier == currentIdentifier)
        }
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppLocalizationTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AppLocalizationTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private enum AppLocalizationTestError: Error {
    case defaultsUnavailable
}
