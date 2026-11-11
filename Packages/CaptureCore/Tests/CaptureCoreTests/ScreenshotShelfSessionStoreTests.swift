import Foundation
import Testing

@testable import CaptureCore

struct ScreenshotShelfSessionStoreTests {
    @Test func encryptsOriginalOnDiskAndRoundTripsForSameStore() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ScreenshotShelfSessionStore(
            sessionRootURL: root,
            originalByteBudget: 1_024,
            thumbnailByteBudget: 1_024
        )
        let captureID = UUID()
        let original = Data("shelf-original-image".utf8)
        let thumbnail = Data("thumbnail".utf8)

        let evictedIDs = try await store.store(
            originalData: original,
            thumbnailData: thumbnail,
            captureID: captureID
        )

        let restored = try await store.originalData(for: captureID)
        let cachedThumbnail = await store.thumbnailData(for: captureID)
        let sessionDirectories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: sessionDirectories[0],
            includingPropertiesForKeys: nil
        )
        let ciphertext = try Data(contentsOf: storedFiles[0])

        #expect(evictedIDs.isEmpty)
        #expect(restored == original)
        #expect(cachedThumbnail == thumbnail)
        #expect(ciphertext != original)
        #expect(ciphertext.range(of: original) == nil)
    }

    @Test func evictsOldestAssetWhenEncryptedOriginalBudgetIsExceeded() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ScreenshotShelfSessionStore(
            sessionRootURL: root,
            originalByteBudget: 128,
            thumbnailByteBudget: 256
        )
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let firstOriginal = Data(repeating: 1, count: 32)
        let secondOriginal = Data(repeating: 2, count: 32)
        let thirdOriginal = Data(repeating: 3, count: 32)
        let thumbnail = Data(repeating: 9, count: 16)

        _ = try await store.store(
            originalData: firstOriginal,
            thumbnailData: thumbnail,
            captureID: firstID
        )
        _ = try await store.store(
            originalData: secondOriginal,
            thumbnailData: thumbnail,
            captureID: secondID
        )
        let evictedIDs = try await store.store(
            originalData: thirdOriginal,
            thumbnailData: thumbnail,
            captureID: thirdID
        )

        let firstOriginalAfterEviction = try await store.originalData(for: firstID)
        let secondOriginalAfterEviction = try await store.originalData(for: secondID)
        let thirdOriginalAfterEviction = try await store.originalData(for: thirdID)
        let firstThumbnailAfterEviction = await store.thumbnailData(for: firstID)

        #expect(evictedIDs == [firstID])
        #expect(firstOriginalAfterEviction == nil)
        #expect(firstThumbnailAfterEviction == nil)
        #expect(secondOriginalAfterEviction == secondOriginal)
        #expect(thirdOriginalAfterEviction == thirdOriginal)
    }

    @Test func evictsOldestAssetWhenThumbnailBudgetIsExceeded() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ScreenshotShelfSessionStore(
            sessionRootURL: root,
            originalByteBudget: 512,
            thumbnailByteBudget: 32
        )
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let original = Data(repeating: 7, count: 8)
        let firstThumbnail = Data(repeating: 1, count: 16)
        let secondThumbnail = Data(repeating: 2, count: 16)
        let thirdThumbnail = Data(repeating: 3, count: 16)

        _ = try await store.store(
            originalData: original,
            thumbnailData: firstThumbnail,
            captureID: firstID
        )
        _ = try await store.store(
            originalData: original,
            thumbnailData: secondThumbnail,
            captureID: secondID
        )
        let evictedIDs = try await store.store(
            originalData: original,
            thumbnailData: thirdThumbnail,
            captureID: thirdID
        )

        let firstOriginalAfterEviction = try await store.originalData(for: firstID)
        let secondThumbnailAfterEviction = await store.thumbnailData(for: secondID)
        let thirdThumbnailAfterEviction = await store.thumbnailData(for: thirdID)

        #expect(evictedIDs == [firstID])
        #expect(firstOriginalAfterEviction == nil)
        #expect(secondThumbnailAfterEviction == secondThumbnail)
        #expect(thirdThumbnailAfterEviction == thirdThumbnail)
    }

    @Test func refusesOversizedOriginalWithoutDeletingExistingAssets() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ScreenshotShelfSessionStore(
            sessionRootURL: root,
            originalByteBudget: 128,
            thumbnailByteBudget: 128
        )
        let existingID = UUID()
        let refusedID = UUID()
        let existingOriginal = Data(repeating: 5, count: 32)
        let existingThumbnail = Data(repeating: 6, count: 16)
        _ = try await store.store(
            originalData: existingOriginal,
            thumbnailData: existingThumbnail,
            captureID: existingID
        )

        do {
            _ = try await store.store(
                originalData: Data(repeating: 8, count: 200),
                thumbnailData: Data(repeating: 9, count: 8),
                captureID: refusedID
            )
            Issue.record("Expected an explicit refusal for an original larger than the budget.")
        } catch let error as ScreenshotShelfSessionStoreError {
            #expect(error == .originalExceedsBudget)
        }

        let existingOriginalAfterRefusal = try await store.originalData(for: existingID)
        let existingThumbnailAfterRefusal = await store.thumbnailData(for: existingID)
        let refusedOriginal = try await store.originalData(for: refusedID)

        #expect(existingOriginalAfterRefusal == existingOriginal)
        #expect(existingThumbnailAfterRefusal == existingThumbnail)
        #expect(refusedOriginal == nil)
    }

    @Test func initializationRemovesOnlyDeadSessionDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let liveDirectory = root.appendingPathComponent(
            ScreenshotShelfSessionDirectoryPolicy.directoryName(
                ownerPID: getpid(),
                sessionID: UUID()
            ),
            isDirectory: true
        )
        let deadDirectory = root.appendingPathComponent(
            ScreenshotShelfSessionDirectoryPolicy.directoryName(
                ownerPID: deadProcessID(),
                sessionID: UUID()
            ),
            isDirectory: true
        )
        let legacyDirectory = root.appendingPathComponent(
            "session-\(UUID().uuidString)",
            isDirectory: true
        )
        let unrelatedFile = root.appendingPathComponent("notes.txt")
        for directory in [liveDirectory, deadDirectory, legacyDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("asset".utf8).write(to: directory.appendingPathComponent("asset.bin"))
        }
        try Data("keep".utf8).write(to: unrelatedFile)
        try setModificationDate(now.addingTimeInterval(-3_600), for: liveDirectory)
        try setModificationDate(now.addingTimeInterval(-3_600), for: deadDirectory)
        try setModificationDate(now.addingTimeInterval(-25 * 60 * 60), for: legacyDirectory)

        _ = try ScreenshotShelfSessionStore(
            sessionRootURL: root,
            originalByteBudget: 128,
            thumbnailByteBudget: 128
        )

        let remainingItems = try FileManager.default.contentsOfDirectory(atPath: root.path)

        #expect(FileManager.default.fileExists(atPath: liveDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: deadDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: legacyDirectory.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
        // The live directory, the unrelated file, and this store's own directory.
        #expect(remainingItems.count == 3)
    }

    @Test func recreatesTheSessionDirectoryAfterItDisappears() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ScreenshotShelfSessionStore(
            sessionRootURL: root,
            originalByteBudget: 1_024,
            thumbnailByteBudget: 1_024
        )
        let firstID = UUID()
        let firstOriginal = Data("first-original".utf8)
        try await store.store(
            originalData: firstOriginal,
            thumbnailData: Data("thumb".utf8),
            captureID: firstID
        )
        let sessionDirectory = try #require(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix("session-") })
        )
        try FileManager.default.removeItem(at: sessionDirectory)

        let secondID = UUID()
        let secondOriginal = Data("second-original".utf8)
        try await store.store(
            originalData: secondOriginal,
            thumbnailData: Data("thumb".utf8),
            captureID: secondID
        )

        #expect(try await store.originalData(for: secondID) == secondOriginal)
        // The first asset's file disappeared with the directory; it must not be
        // advertised anymore.
        #expect(try await store.originalData(for: firstID) == nil)
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func deadProcessID() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        do {
            try process.run()
            process.waitUntilExit()
            return process.processIdentifier
        } catch {
            return Int32.max
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".screenshot-shelf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
