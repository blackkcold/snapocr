import Foundation
import SharedKit

/// Resolves UI strings against the language chosen in Settings rather than the
/// system language that `NSLocalizedString` / `String(localized:)` follow.
/// SwiftUI views already track the injected `\.locale`; this serves the
/// Foundation paths that cannot: toasts, alerts, panels, and AppKit menus.
enum AppLocalization {
    private static func bundle() -> Bundle {
        let language = UserDefaults.standard.string(forKey: PreferenceKeys.appLanguage)
            ?? PreferenceDefaults.appLanguage
        guard let identifier = AppLanguage(rawValue: language)?.resourceIdentifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return .main
        }
        return languageBundle
    }

    static func string(_ key: String) -> String {
        bundle().localizedString(forKey: key, value: nil, table: nil)
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: bundle().localizedString(forKey: key, value: nil, table: nil), arguments: arguments)
    }
}
