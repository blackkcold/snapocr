import CaptureCore
import OCRCore
import SharedKit
import SwiftUI

// MARK: - CaptureViewModel Preferences & Static Helpers

extension CaptureViewModel {
    static func boolPreference(forKey key: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func currentCaptureOptions() -> CaptureOptions {
        let highResolution = boolPreference(
            forKey: PreferenceKeys.captureHighResolution,
            defaultValue: PreferenceDefaults.captureHighResolution
        )
        return CaptureOptions(
            includeCursor: boolPreference(
                forKey: PreferenceKeys.captureIncludeCursor,
                defaultValue: PreferenceDefaults.captureIncludeCursor
            ),
            highResolution: highResolution,
            preferredScaleFactor: highResolution ? 2 : 1
        )
    }

    static func currentOCROptions() -> OCROptions {
        OCRSettings.current()
    }

    static func stringPreference(forKey key: String, defaultValue: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? defaultValue
    }

    private static func doublePreference(forKey key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return UserDefaults.standard.double(forKey: key)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func historyModeDescription(for mode: CaptureCore.CaptureMode) -> String {
        switch mode {
        case .area:
            return "area"
        case .window:
            return "window"
        case .fullscreen:
            return "fullscreen"
        case .scroll:
            return "scroll"
        }
    }
}
