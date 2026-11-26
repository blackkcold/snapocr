import Foundation
import SharedKit

/// Well-known on-disk locations used by the library.
public enum LibraryPaths {
    /// Metadata file of the recording library inside Application Support.
    public static var metadataFileURL: URL {
        URL.appSupportDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(RecordingLibraryStore.defaultFileName)
    }

    /// Directory that holds generated recording thumbnails.
    public static var thumbnailDirectory: URL {
        URL.appSupportDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// Default directory for exported merged recordings.
    public static var defaultExportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    /// Creates the library, thumbnail and export directories if they are
    /// missing.
    ///
    /// Failures are ignored, so a caller that must write should still check the
    /// resulting paths.
    public static func ensureDirectories() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: metadataFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: thumbnailDirectory,
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: defaultExportDirectory,
            withIntermediateDirectories: true
        )
    }
}
