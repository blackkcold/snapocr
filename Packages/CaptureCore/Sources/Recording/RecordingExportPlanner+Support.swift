import Foundation

// MARK: Filesystem and path helpers

extension RecordingExportPlanner {
    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func isExistingDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func validStem(_ stem: String) -> Bool {
        !stem.isEmpty && stem != "." && stem != ".." && !stem.hasPrefix(".")
            && !stem.contains("/") && !stem.contains("\\") && !stem.contains("\0")
    }
}
