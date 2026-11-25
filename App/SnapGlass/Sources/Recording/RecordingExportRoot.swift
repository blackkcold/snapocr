import CaptureCore
import Foundation
import SharedKit

/// One destination folder scanned by the recordings window.
///
/// `kind` labels the folder that owned the setting; a session's own
/// `RecordingSessionRecord.kind` remains authoritative for display and export.
struct RecordingExportRoot: Sendable, Hashable {
    let kind: RecordingKind
    let root: URL
    let indexURL: URL

    init(kind: RecordingKind, root: URL, indexURL: URL? = nil) {
        let standardizedRoot = root.standardizedFileURL
        self.kind = kind
        self.root = standardizedRoot
        self.indexURL =
            indexURL?.standardizedFileURL
            ?? standardizedRoot
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")
    }
}

/// Builds the folders worth scanning for completed recordings.
enum RecordingExportRoots {
    /// Current audio and screen folders, then previously used folders.
    ///
    /// Remembered and legacy folders are discovery-only: they never change where
    /// the next recording is written. Duplicate standardized paths are scanned once.
    static func current(
        in defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [RecordingExportRoot] {
        // The agent channel never scans or writes the user's library: every
        // export/scan path resolves the isolated root instead.
        if let agentRoot = AgentIsolation.recordingRoot() {
            return [RecordingExportRoot(kind: .screen, root: agentRoot)]
        }

        RecordingDestinationPreferences.seedLegacySharedValuesIfNeeded(in: defaults)

        var roots: [RecordingExportRoot] = []
        var seenPaths = Set<String>()

        func append(kind: RecordingKind, directory: URL?) {
            guard let directory else { return }
            let standardized = directory.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { return }
            roots.append(RecordingExportRoot(kind: kind, root: standardized))
        }

        // Screen first so a shared folder keeps the plan's single `.screen` label.
        append(
            kind: .screen,
            directory: RecordingDestinationPreferences.directory(
                for: .screen,
                in: defaults,
                fileManager: fileManager
            )
        )
        append(
            kind: .audio,
            directory: RecordingDestinationPreferences.directory(
                for: .audio,
                in: defaults,
                fileManager: fileManager
            )
        )
        for directory in RecordingDestinationPreferences.knownDirectories(in: defaults) {
            append(kind: .screen, directory: directory)
        }

        if roots.isEmpty {
            let fallback = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies", isDirectory: true)
                .appendingPathComponent("SnapGlass", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
            roots.append(RecordingExportRoot(kind: .screen, root: fallback))
        }
        return roots
    }
}

extension RecordingKind {
    /// Maps a capture kind to its kind-agnostic preference domain.
    var outputKind: RecordingOutputKind {
        self == .audio ? .audio : .screen
    }
}
