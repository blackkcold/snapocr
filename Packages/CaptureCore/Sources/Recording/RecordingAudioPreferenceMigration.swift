/// Resolves the persisted audio-source preferences for audio-only and screen recordings.
///
/// The resolver is a pure function over already-read preference values. Callers persist the
/// returned modes only when the matching `persist` flag is `true`, which keeps repeated
/// resolutions idempotent and leaves the legacy system-audio flag untouched.
public enum RecordingAudioPreferenceMigration {
    /// The effective modes and the writes needed to persist them.
    public struct Resolution: Equatable, Sendable {
        /// The audio-source mode used by audio-only recordings.
        public let audioMode: AudioSourceMode
        /// The audio-source mode used by screen recordings.
        public let screenMode: AudioSourceMode
        /// Whether the audio-only mode should be written to its preference key.
        public let persistAudioMode: Bool
        /// Whether the screen mode should be written to its preference key.
        public let persistScreenMode: Bool

        /// Creates a migration resolution.
        ///
        /// - Parameters:
        ///   - audioMode: The resolved audio-only mode.
        ///   - screenMode: The resolved screen-recording mode.
        ///   - persistAudioMode: Whether the audio-only mode needs to be persisted.
        ///   - persistScreenMode: Whether the screen mode needs to be persisted.
        public init(
            audioMode: AudioSourceMode,
            screenMode: AudioSourceMode,
            persistAudioMode: Bool,
            persistScreenMode: Bool
        ) {
            self.audioMode = audioMode
            self.screenMode = screenMode
            self.persistAudioMode = persistAudioMode
            self.persistScreenMode = persistScreenMode
        }
    }

    /// Resolves both recording modes from persisted values and the legacy flag.
    ///
    /// Audio-only recordings always default to `.systemAndMicrophone` and never consult the
    /// legacy screen-recording flag. Screen recordings preserve an existing mode; when the new
    /// key is absent, a legacy `true` migrates to `.system`, a legacy `false` to `.none`, and a
    /// missing legacy value to the `.system` default.
    ///
    /// - Parameters:
    ///   - audioMode: The persisted audio-only mode, or `nil` when its key is absent.
    ///   - screenMode: The persisted screen mode, or `nil` when its key is absent.
    ///   - legacySystemAudio: The legacy flag, or `nil` when the user has no stored value.
    /// - Returns: The effective modes and which of them need to be persisted.
    public static func resolve(
        audioMode: AudioSourceMode?,
        screenMode: AudioSourceMode?,
        legacySystemAudio: Bool?
    ) -> Resolution {
        let resolvedScreenMode: AudioSourceMode
        if let screenMode {
            resolvedScreenMode = screenMode
        } else if let legacySystemAudio {
            resolvedScreenMode = legacySystemAudio ? .system : .none
        } else {
            resolvedScreenMode = .system
        }

        return Resolution(
            audioMode: audioMode ?? .systemAndMicrophone,
            screenMode: resolvedScreenMode,
            persistAudioMode: audioMode == nil,
            persistScreenMode: screenMode == nil
        )
    }

    /// Decodes a persisted audio-source preference value.
    ///
    /// - Parameter value: The stored string, or `nil` when the key is absent.
    /// - Returns: The matching mode, or `nil` for missing or unknown values.
    public static func mode(fromPreferenceValue value: String?) -> AudioSourceMode? {
        switch value {
        case "system":
            return .system
        case "microphone":
            return .microphone
        case "systemAndMicrophone":
            return .systemAndMicrophone
        case "none":
            return AudioSourceMode.none
        default:
            return nil
        }
    }

    /// Encodes an audio-source mode as its persisted preference value.
    ///
    /// - Parameter mode: The mode to encode.
    /// - Returns: The stable string stored in preferences.
    public static func preferenceValue(for mode: AudioSourceMode) -> String {
        switch mode {
        case .system:
            return "system"
        case .microphone:
            return "microphone"
        case .systemAndMicrophone:
            return "systemAndMicrophone"
        case .none:
            return "none"
        }
    }
}
