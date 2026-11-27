import Foundation

/// Reads the persisted OCR language order and migrates the old English-first default.
///
/// Vision picks its recognition model from the first enabled language under
/// `.accurate`, so the order is a user-visible behaviour, not a cosmetic detail.
/// The default changed to Chinese-first; a stored array equal to the old default
/// must therefore be treated as "never chosen", otherwise every existing user —
/// whose array was written by the Preferences toggles — keeps the Latin model and
/// never sees the fix.
///
/// A user who arranged the languages themselves keeps that arrangement: only the
/// exact legacy default is replaced, and a one-time marker stops the replacement
/// from ever touching an order chosen after the migration.
public enum OCRLanguagePreferences {
    /// The English-first default that shipped before Chinese led the list.
    public static let legacyDefaultLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko"]

    /// Returns the effective enabled languages, newest first, migrating once.
    ///
    /// The first call on a store holding the legacy default writes the new default
    /// and the migration marker, so the Preferences UI and every OCR caller read the
    /// same order afterwards. Later calls — and stores that never held the legacy
    /// default — are pure reads of what the user (or the new default) put there.
    ///
    /// - Parameter defaults: Defaults store holding the OCR language order.
    /// - Returns: The languages OCR may use, in priority order.
    public static func enabledLanguages(in defaults: UserDefaults = .standard) -> [String] {
        guard
            let stored = defaults.stringArray(forKey: PreferenceKeys.ocrEnabledLanguages),
            !stored.isEmpty
        else {
            return PreferenceDefaults.ocrEnabledLanguages
        }
        guard stored == legacyDefaultLanguages else { return stored }
        guard defaults.object(forKey: PreferenceKeys.ocrLanguageOrderMigrated) == nil else {
            // The marker exists, so this array was chosen after the migration ran.
            return stored
        }

        let migrated = PreferenceDefaults.ocrEnabledLanguages
        defaults.set(migrated, forKey: PreferenceKeys.ocrEnabledLanguages)
        defaults.set(true, forKey: PreferenceKeys.ocrLanguageOrderMigrated)
        return migrated
    }

    /// Records an order the user arranged themselves.
    ///
    /// Writing the marker is what makes the order stick: without it, a user who
    /// deliberately recreated the legacy English-first order would have it replaced
    /// by the migration on the next read. Every write from the Preferences UI must
    /// go through here.
    ///
    /// - Parameters:
    ///   - languages: The enabled languages in the user's chosen order.
    ///   - defaults: Defaults store holding the OCR language order.
    public static func setEnabledLanguages(_ languages: [String], in defaults: UserDefaults = .standard) {
        defaults.set(languages, forKey: PreferenceKeys.ocrEnabledLanguages)
        defaults.set(true, forKey: PreferenceKeys.ocrLanguageOrderMigrated)
    }
}
