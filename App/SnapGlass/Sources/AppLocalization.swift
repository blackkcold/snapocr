import Foundation
import CaptureCore
import SharedKit

/// Resolves UI strings against the language chosen in Settings rather than the
/// system language that `NSLocalizedString` / `String(localized:)` follow.
/// SwiftUI views already track the injected `\.locale`; this serves the
/// Foundation paths that cannot: toasts, alerts, panels, and AppKit menus.
enum AppLocalization {
    private static func language(in defaults: UserDefaults) -> AppLanguage {
        let rawValue = defaults.string(forKey: PreferenceKeys.appLanguage)
            ?? PreferenceDefaults.appLanguage
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static func locale(in defaults: UserDefaults = .standard) -> Locale {
        language(in: defaults).locale
    }

    private static func bundle() -> Bundle {
        guard let identifier = language(in: .standard).resourceIdentifier,
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

    static func recordingErrorDescription(_ error: Error) -> String {
        recordingErrorDescription(error, localize: { key in string(key) })
    }

    static func recordingErrorDescription(
        _ error: Error,
        localize: (String) -> String
    ) -> String {
        if let engineError = error as? ScreenRecordingEngineError {
            return recordingErrorDescription(engineError, localize: localize)
        }
        if let configurationError = error as? RecordingConfigurationError {
            switch configurationError {
            case .unsupportedCodec:
                return localize("The selected video codec is not supported by the media writer.")
            case .unsupportedSystemAudioFormat:
                return localize("The selected system audio format is unavailable.")
            case .invalidConfiguration:
                return localize("The recording settings are invalid.")
            }
        }
        return error.localizedDescription
    }

    static func recordingErrorDescription(
        _ error: ScreenRecordingEngineError,
        localize: (String) -> String
    ) -> String {
        switch error {
        case let .sourceUnavailable(reason):
            return localize(reason)
        case .invalidRegion:
            return localize("The recording region is outside the selected display.")
        case .invalidSourceDimensions:
            return localize("The recording source has invalid dimensions.")
        case .invalidOutputDimensions:
            return localize("The recording source cannot produce valid even-sized output dimensions.")
        case let .writerInputUnavailable(mediaType):
            return formatted(
                "The media writer cannot encode the requested %@ format.",
                arguments: [localize(mediaType)],
                localize: localize
            )
        case let .recordingFailed(reason, partialURL), let .finalizationFailed(reason, partialURL):
            let localizedReason = localizedRecordingReason(reason, localize: localize)
            guard let partialURL else { return localizedReason }
            let retainedPartial = formatted(
                "Retained partial: %@",
                arguments: [partialURL.path],
                localize: localize
            )
            return "\(localizedReason) \(retainedPartial)"
        }
    }

    private static func localizedRecordingReason(
        _ reason: String,
        localize: (String) -> String
    ) -> String {
        let captureStopPrefix = "The capture stream could not stop cleanly: "
        guard reason.hasPrefix(captureStopPrefix) else { return localize(reason) }

        let underlyingReason = String(reason.dropFirst(captureStopPrefix.count))
        return formatted(
            "The capture stream could not stop cleanly: %@",
            arguments: [underlyingReason],
            localize: localize
        )
    }

    private static func formatted(
        _ key: String,
        arguments: [CVarArg],
        localize: (String) -> String
    ) -> String {
        String(format: localize(key), arguments: arguments)
    }
}
