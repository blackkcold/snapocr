import Foundation
import Testing
@testable import LibraryCore

@Suite("Thumbnail cache maintenance")
struct RecordingThumbnailCacheTests {
    @Test("Old files and over-budget files are removed")
    func prunesOldAndOverBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldURL = directory.appendingPathComponent("old.png")
        let recentURL = directory.appendingPathComponent("recent.png")
        try Data([0x01]).write(to: oldURL)
        try Data(repeating: 0x02, count: 128).write(to: recentURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10_000)],
            ofItemAtPath: oldURL.path
        )

        let service = RecordingThumbnailService(cacheDirectory: directory)
        await service.pruneCache(olderThan: 60, maxBytes: 64)

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(!FileManager.default.fileExists(atPath: recentURL.path))
    }
}
