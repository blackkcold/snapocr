import Foundation
import SharedKit

/// Runtime rollback switch for the unified library.
///
/// Defaults to on. The environment override is for local support/rollback only;
/// it is not a GUI automation hook.
enum LibraryFeature {
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["SNAPGLASS_LEGACY_HISTORY"] == "1" {
            return false
        }
        return UserDefaults.standard.object(forKey: PreferenceKeys.libraryUnifiedEnabled) as? Bool
            ?? PreferenceDefaults.libraryUnifiedEnabled
    }
}
