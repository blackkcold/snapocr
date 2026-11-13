import Testing

@testable import CaptureCore

@Suite("Recording audio preference migration")
struct RecordingAudioPreferenceMigrationTests {
    @Test("Audio-only recordings default to system and microphone regardless of the legacy flag")
    func audioOnlyIgnoresLegacySystemAudio() {
        let resolution = RecordingAudioPreferenceMigration.resolve(
            audioMode: nil,
            screenMode: nil,
            legacySystemAudio: false
        )

        #expect(resolution.audioMode == .systemAndMicrophone)
        #expect(resolution.persistAudioMode)
    }

    @Test("A fresh install without any legacy value defaults both modes")
    func freshInstallDefaultsBothModes() {
        let resolution = RecordingAudioPreferenceMigration.resolve(
            audioMode: nil,
            screenMode: nil,
            legacySystemAudio: nil
        )

        #expect(resolution.audioMode == .systemAndMicrophone)
        #expect(resolution.screenMode == .system)
        #expect(resolution.persistAudioMode)
        #expect(resolution.persistScreenMode)
    }

    @Test("Legacy system audio enabled migrates screen recordings to system audio")
    func legacyEnabledMigratesScreenToSystem() {
        let resolution = RecordingAudioPreferenceMigration.resolve(
            audioMode: .systemAndMicrophone,
            screenMode: nil,
            legacySystemAudio: true
        )

        #expect(resolution.screenMode == .system)
        #expect(resolution.persistScreenMode)
    }

    @Test("Legacy system audio disabled migrates screen recordings to no audio")
    func legacyDisabledMigratesScreenToNone() {
        let resolution = RecordingAudioPreferenceMigration.resolve(
            audioMode: .systemAndMicrophone,
            screenMode: nil,
            legacySystemAudio: false
        )

        #expect(resolution.screenMode == .none)
        #expect(resolution.persistScreenMode)
    }

    @Test("An existing screen mode is preserved over the legacy value")
    func existingScreenModeWins() {
        let resolution = RecordingAudioPreferenceMigration.resolve(
            audioMode: .system,
            screenMode: .microphone,
            legacySystemAudio: true
        )

        #expect(resolution.screenMode == .microphone)
        #expect(!resolution.persistScreenMode)
        #expect(!resolution.persistAudioMode)
    }

    @Test("An existing audio mode is preserved over the legacy value")
    func existingAudioModeWins() {
        let resolution = RecordingAudioPreferenceMigration.resolve(
            audioMode: .system,
            screenMode: .none,
            legacySystemAudio: false
        )

        #expect(resolution.audioMode == .system)
        #expect(!resolution.persistAudioMode)
    }

    @Test("Resolving already persisted modes requests no further writes")
    func secondResolutionIsIdempotent() {
        let first = RecordingAudioPreferenceMigration.resolve(
            audioMode: nil,
            screenMode: nil,
            legacySystemAudio: true
        )
        let second = RecordingAudioPreferenceMigration.resolve(
            audioMode: first.audioMode,
            screenMode: first.screenMode,
            legacySystemAudio: true
        )

        #expect(second.audioMode == first.audioMode)
        #expect(second.screenMode == first.screenMode)
        #expect(!second.persistAudioMode)
        #expect(!second.persistScreenMode)
    }

    @Test("Preference values map to every audio source mode")
    func preferenceValuesRoundTrip() {
        #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: "system") == .system)
        #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: "microphone") == .microphone)
        #expect(
            RecordingAudioPreferenceMigration.mode(fromPreferenceValue: "systemAndMicrophone")
                == .systemAndMicrophone
        )
        #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: "none") == AudioSourceMode.none)

        for mode: AudioSourceMode in [.system, .microphone, .systemAndMicrophone, .none] {
            let value = RecordingAudioPreferenceMigration.preferenceValue(for: mode)
            #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: value) == mode)
        }
    }

    @Test("Unknown or missing preference values do not resolve to a mode")
    func unknownPreferenceValuesAreNil() {
        #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: nil) == nil)
        #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: "") == nil)
        #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: "System") == nil)
        #expect(RecordingAudioPreferenceMigration.mode(fromPreferenceValue: "futureMode") == nil)
    }
}
