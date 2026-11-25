import CaptureCore
import Foundation
import SharedKit

/// Resolves UI strings against the language chosen in Settings rather than the
/// system language that `NSLocalizedString` / `String(localized:)` follow.
/// SwiftUI views already track the injected `\.locale`; this serves the
/// Foundation paths that cannot: toasts, alerts, panels, and AppKit menus.
enum AppLocalization {
    private static func language(in defaults: UserDefaults) -> AppLanguage {
        let rawValue =
            defaults.string(forKey: PreferenceKeys.appLanguage)
            ?? PreferenceDefaults.appLanguage
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    static func locale(in defaults: UserDefaults = .standard) -> Locale {
        language(in: defaults).locale
    }

    /// A stable identifier for the language the UI renders in.
    ///
    /// Part of the recording HUD's layout-signature key: the same state measures a
    /// different width per translation, so a language change invalidates a cached size.
    static var languageIdentifier: String {
        let selected = language(in: .standard)
        return "\(selected.rawValue):\(selected.locale.identifier)"
    }

    private static func bundle() -> Bundle {
        guard let identifier = language(in: .standard).resourceIdentifier,
            let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
            let languageBundle = Bundle(path: path)
        else {
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
        if let pipelineError = error as? RecordingPipelineError {
            return pipelineErrorDescription(pipelineError, localize: localize)
        }
        if let engineError = error as? ScreenRecordingEngineError {
            return recordingErrorDescription(engineError, localize: localize)
        }
        if let coordinatorError = error as? ScreenRecordingSessionCoordinatorError {
            return coordinatorErrorDescription(coordinatorError, localize: localize)
        }
        if let configurationError = error as? RecordingConfigurationError {
            return configurationErrorDescription(configurationError, localize: localize)
        }
        return error.localizedDescription
    }

    private static func pipelineErrorDescription(
        _ error: RecordingPipelineError,
        localize: (String) -> String
    ) -> String {
        switch error {
        case .alreadyStarted:
            return localize("A recording is already starting or in progress.")
        case .invalidConfiguration:
            return localize("The recording settings are invalid.")
        case let .spacePreflightDenied(decision):
            return spaceBudgetDescription(decision, localize: localize)
        case .journalUnavailable:
            return localize("The recording session is unavailable.")
        case .engineUnavailable:
            return localize("The audio recording engine could not start.")
        }
    }

    private static func coordinatorErrorDescription(
        _ error: ScreenRecordingSessionCoordinatorError,
        localize: (String) -> String
    ) -> String {
        switch error {
        case .alreadyStarted:
            return localize("A recording is already starting or in progress.")
        case .notStarted:
            return localize("The recording session is unavailable.")
        case .noPublishedSegments:
            return localize("The screen recording did not publish a video segment.")
        case .invalidConfiguration:
            return localize("The recording settings are invalid.")
        case .audioFinalizationFailed:
            return localize("Screen-recording audio could not be finalized.")
        case .streamStopUnconfirmed:
            return localize(
                // swiftlint:disable:next line_length
                "The capture stream did not confirm it stopped. Your recording was kept; wait for it to stop before starting another one."
            )
        }
    }

    private static func configurationErrorDescription(
        _ error: RecordingConfigurationError,
        localize: (String) -> String
    ) -> String {
        switch error {
        case .unsupportedCodec:
            return localize("The selected video codec is not supported by the media writer.")
        case .unsupportedSystemAudioFormat:
            return localize("The selected system audio format is unavailable.")
        case .invalidConfiguration:
            return localize("The recording settings are invalid.")
        }
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
        case .previousStreamNotStopped:
            return localize("The previous capture stream has not stopped yet. Wait for it to stop, then record again.")
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

    private static func spaceBudgetDescription(
        _ decision: SpaceBudgetDecision,
        localize: (String) -> String
    ) -> String {
        switch decision.denial {
        case let .insufficient(_, available, required)?:
            return formatted(
                "Not enough space: %@ available, %@ required.",
                arguments: [
                    RecordingStorage.formattedBytes(available),
                    RecordingStorage.formattedBytes(required),
                ],
                localize: localize
            )
        case .capacityUnreadable(_)?:
            return localize("Could not check free space in the recording folder.")
        case .locationUnavailable(_, _)?:
            return localize("The selected recording folder is unavailable. Choose it again in Preferences.")
        case .none:
            return localize("At least 1 GB of free space is required to start recording.")
        }
    }

    private static func formatted(
        _ key: String,
        arguments: [CVarArg],
        localize: (String) -> String
    ) -> String {
        String(format: localize(key), arguments: arguments)
    }
}
