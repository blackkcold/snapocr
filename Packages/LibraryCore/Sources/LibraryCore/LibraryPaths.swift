import Foundation
import SharedKit

public enum LibraryPaths {
    public static var metadataFileURL: URL {
        URL.appSupportDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(RecordingLibraryStore.defaultFileName)
    }

    public static var thumbnailDirectory: URL {
        URL.appSupportDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    public static var defaultExportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("SnapGlass", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

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
