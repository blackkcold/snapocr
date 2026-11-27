import Foundation

/// Reads the persisted OCR language order and migrates the old English-first order once.
///
/// Vision picks its recognition model from the first enabled language under
/// `.accurate`, so the order is a user-visible behaviour, not a cosmetic detail.
/// The default changed to Chinese-first; an English-first stored order must
/// therefore be treated as "never chosen", otherwise every existing user keeps
/// the Latin model and never sees the fix.
///
/// The Preferences window only offers per-language switches — there is no
/// reorder control — so a stored array is always `PreferenceDefaults` minus the
/// languages the user turned off: its order carries no intent. That is why the
/// migration keys off the leading language rather than an exact match against
/// the old default, and why it only moves Simplified Chinese: the enabled set is
/// the part the user actually expressed.
///
/// A one-time marker stops the reorder from ever touching an order chosen after
/// the migration. Every write from the Preferences UI records that marker, so a
/// user who later puts English back in front keeps it.
public enum OCRLanguagePreferences {
    /// The language that led the list before Chinese-first became the default.
    public static let legacyLeadingLanguage = "en"

    /// Simplified Chinese, the language the new default leads with.
    public static let simplifiedChinese = "zh-Hans"

    /// Returns the effective enabled languages in priority order, migrating once.
    ///
    /// A store whose order starts with English and has no migration marker is
    /// reordered once so Simplified Chinese leads. Only the order changes: the
    /// enabled set is preserved exactly, so languages the user turned off are
    /// never added back, and a store without Simplified Chinese keeps its own
    /// order rather than having a language inserted.
    ///
    /// The marker is written on that first pass even when the order does not
    /// change (English first, Chinese disabled): the reorder has been evaluated
    /// for this store, and re-evaluating it on every read would make a later
    /// change to this rule silently rewrite an order the user has since chosen.
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
        guard defaults.object(forKey: PreferenceKeys.ocrLanguageOrderMigrated) == nil else {
            // The marker exists, so this array was chosen after the migration ran.
            return stored
        }
        guard stored.first == legacyLeadingLanguage else { return stored }

        let migrated = chineseFirst(stored)
        if migrated != stored {
            defaults.set(migrated, forKey: PreferenceKeys.ocrEnabledLanguages)
        }
        defaults.set(true, forKey: PreferenceKeys.ocrLanguageOrderMigrated)
        return migrated
    }

    /// Records an order the user arranged themselves.
    ///
    /// Writing the marker is what makes the order stick: without it, a user who
    /// deliberately recreated the English-first order would have it replaced by
    /// the migration on the next read. Every write from the Preferences UI must
    /// go through here.
    ///
    /// - Parameters:
    ///   - languages: The enabled languages in the user's chosen order.
    ///   - defaults: Defaults store holding the OCR language order.
    public static func setEnabledLanguages(_ languages: [String], in defaults: UserDefaults = .standard) {
        defaults.set(languages, forKey: PreferenceKeys.ocrEnabledLanguages)
        defaults.set(true, forKey: PreferenceKeys.ocrLanguageOrderMigrated)
    }

    /// Moves Simplified Chinese to the front without changing the enabled set.
    ///
    /// Every other language keeps its relative position, so the result is the
    /// user's own selection with one element hoisted. A store without Simplified
    /// Chinese is returned unchanged: the user turned Chinese off, and inserting
    /// it would override that choice.
    ///
    /// - Parameter languages: The stored languages, in stored order.
    /// - Returns: The same languages with Simplified Chinese first when present.
    static func chineseFirst(_ languages: [String]) -> [String] {
        guard let index = languages.firstIndex(of: simplifiedChinese), index > 0 else {
            return languages
        }
        var reordered = languages
        reordered.remove(at: index)
        reordered.insert(simplifiedChinese, at: 0)
        return reordered
    }
}
