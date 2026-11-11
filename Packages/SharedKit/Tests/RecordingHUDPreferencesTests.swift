import Foundation
import Testing

@testable import SharedKit

struct RecordingHUDPreferencesTests {
    @Test func missingValuesUsePanelDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PreferenceDefaults.recordingHUDOpacity == 0.85)
        #expect(RecordingHUDPreferences.opacity(in: defaults) == 0.85)
        #expect(RecordingHUDPreferences.hoverRestore(in: defaults))
        #expect(!RecordingHUDPreferences.isHidden(in: defaults))
        #expect(RecordingHUDPreferences.showsCaptureFrame(in: defaults))
        #expect(!RecordingHUDPreferences.revealsOnFinish(in: defaults))
    }

    @Test func opacityIsClampedAndWrittenBackWhenCorrected() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0.05, forKey: PreferenceKeys.recordingHUDOpacity)
        #expect(RecordingHUDPreferences.opacity(in: defaults) == 0.30)
        #expect(defaults.double(forKey: PreferenceKeys.recordingHUDOpacity) == 0.30)

        defaults.set(3.0, forKey: PreferenceKeys.recordingHUDOpacity)
        #expect(RecordingHUDPreferences.opacity(in: defaults) == 1.0)
        #expect(defaults.double(forKey: PreferenceKeys.recordingHUDOpacity) == 1.0)

        defaults.set(0.62, forKey: PreferenceKeys.recordingHUDOpacity)
        #expect(RecordingHUDPreferences.opacity(in: defaults) == 0.62)
    }

    @Test func invalidOpacityFallsBackToTheDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: PreferenceKeys.recordingHUDOpacity)
        #expect(RecordingHUDPreferences.opacity(in: defaults) == PreferenceDefaults.recordingHUDOpacity)
    }

    @Test func panelTogglesRoundTripIndependently() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: PreferenceKeys.recordingHUDHoverRestore)
        defaults.set(true, forKey: PreferenceKeys.recordingHUDHidden)
        defaults.set(false, forKey: PreferenceKeys.recordingShowCaptureFrame)
        defaults.set(true, forKey: PreferenceKeys.recordingRevealOnFinish)

        #expect(!RecordingHUDPreferences.hoverRestore(in: defaults))
        #expect(RecordingHUDPreferences.isHidden(in: defaults))
        #expect(!RecordingHUDPreferences.showsCaptureFrame(in: defaults))
        #expect(RecordingHUDPreferences.revealsOnFinish(in: defaults))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "RecordingHUDPreferencesTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RecordingHUDPreferencesTestError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private enum RecordingHUDPreferencesTestError: Error {
    case defaultsUnavailable
}
