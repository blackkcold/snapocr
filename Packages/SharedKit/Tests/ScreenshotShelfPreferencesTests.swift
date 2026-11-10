import Foundation
import Testing

@testable import SharedKit

struct ScreenshotShelfPreferencesTests {
    @Test func missingValuesUseScreenshotShelfDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ScreenshotShelfPreferences.isEnabled(in: defaults))
        #expect(ScreenshotShelfPreferences.count(in: defaults) == 3)
        #expect(ScreenshotShelfPreferences.cardHeight(in: defaults) == 96)
        #expect(ScreenshotShelfPreferences.imageOpacity(in: defaults) == 0.9)
        #expect(ScreenshotShelfPreferences.anchor(in: defaults) == .top)
        #expect(ScreenshotShelfPreferences.collapseToRail(in: defaults))
    }

    @Test func persistedCollapseToRailRoundTrips() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: PreferenceKeys.screenshotShelfCollapseToRail)
        #expect(!ScreenshotShelfPreferences.collapseToRail(in: defaults))

        defaults.set(true, forKey: PreferenceKeys.screenshotShelfCollapseToRail)
        #expect(ScreenshotShelfPreferences.collapseToRail(in: defaults))
    }

    @Test func persistedAnchorRoundTripsAndInvalidValuesFallBackToTop() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(ScreenshotShelfAnchor.bottomTrailing.rawValue, forKey: PreferenceKeys.screenshotShelfAnchor)
        #expect(ScreenshotShelfPreferences.anchor(in: defaults) == .bottomTrailing)

        defaults.set("left-ish", forKey: PreferenceKeys.screenshotShelfAnchor)
        #expect(ScreenshotShelfPreferences.anchor(in: defaults) == .top)
        #expect(defaults.string(forKey: PreferenceKeys.screenshotShelfAnchor) == ScreenshotShelfAnchor.top.rawValue)
    }

    @Test func persistedValuesAreClampedAndNormalizedOnRead() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(9, forKey: PreferenceKeys.screenshotShelfCount)
        defaults.set(200.0, forKey: PreferenceKeys.screenshotShelfCardHeight)
        defaults.set(0.05, forKey: PreferenceKeys.screenshotShelfImageOpacity)

        #expect(ScreenshotShelfPreferences.count(in: defaults) == 6)
        #expect(ScreenshotShelfPreferences.cardHeight(in: defaults) == 160)
        #expect(ScreenshotShelfPreferences.imageOpacity(in: defaults) == 0.2)
        #expect(defaults.integer(forKey: PreferenceKeys.screenshotShelfCount) == 6)
        #expect(defaults.double(forKey: PreferenceKeys.screenshotShelfCardHeight) == 160)
        #expect(defaults.double(forKey: PreferenceKeys.screenshotShelfImageOpacity) == 0.2)
    }

    @Test func recordingPreferenceDefaultsMatchTheNativeCaptureBaseline() {
        #expect(PreferenceDefaults.recordingVideoCodec == "h264")
        #expect(PreferenceDefaults.recordingResolution == "1080p")
        #expect(PreferenceDefaults.recordingFrameRate == 30)
        #expect(PreferenceDefaults.recordingAverageVideoBitrate == 8_000_000)
        #expect(!PreferenceDefaults.recordingSystemAudio)
    }

    @Test func recordingDestinationDefaultsToMoviesWithoutCreatingIt() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileManager = FileManager.default
        let moviesDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("RecordingDestinationPreferencesTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Movies", isDirectory: true)
        let expected = moviesDirectory
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)

        #expect(!fileManager.fileExists(atPath: expected.path))
        #expect(RecordingDestinationPreferences.directory(in: defaults, moviesDirectory: moviesDirectory) == expected)
        #expect(!fileManager.fileExists(atPath: expected.path))
    }

    @Test func recordingDestinationRemembersAndResetsWithoutMovingExistingFiles() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("RecordingDestinationPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        let customDirectory = testRoot.appendingPathComponent("Custom", isDirectory: true)
        let existingFile = customDirectory.appendingPathComponent("existing.mp4")
        let moviesDirectory = testRoot.appendingPathComponent("Movies", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try Data("keep this recording".utf8).write(to: existingFile)

        RecordingDestinationPreferences.setCustomDirectory(customDirectory, in: defaults)
        let resolved = RecordingDestinationPreferences.directory(
            in: defaults,
            moviesDirectory: moviesDirectory
        )
        #expect(resolved == customDirectory)

        RecordingDestinationPreferences.reset(in: defaults)
        #expect(
            RecordingDestinationPreferences.directory(in: defaults, moviesDirectory: moviesDirectory)
                == moviesDirectory
                    .appendingPathComponent("SnapGlass", isDirectory: true)
                    .appendingPathComponent("Recordings", isDirectory: true)
        )
        #expect(try Data(contentsOf: existingFile) == Data("keep this recording".utf8))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ScreenshotShelfPreferencesTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileReadUnknown)
        }
        return (defaults, suiteName)
    }
}
