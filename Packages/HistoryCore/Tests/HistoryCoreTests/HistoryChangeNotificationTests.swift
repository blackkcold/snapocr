import Foundation
import Testing
import os

@testable import HistoryCore

struct HistoryChangeNotificationTests {
    @Test func deletePostsImageChangeAfterTheEntryIsRemoved() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let history = try HistoryActor(baseURL: root)
        let entry = HistoryEntry(textContent: "delete me", ocrConfidence: 1, captureMode: "area")
        try await history.save(entry)

        let notificationCount = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: HistoryActor.imagesDidChange,
            object: history,
            queue: nil
        ) { _ in
            notificationCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await history.delete(id: entry.id)

        let observedCount = notificationCount.withLock { $0 }
        let deletedEntry = try await history.load(id: entry.id)
        #expect(observedCount == 1)
        #expect(deletedEntry == nil)
    }

    @Test func clearPostsImageChangeAfterAllEntriesAreRemoved() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let history = try HistoryActor(baseURL: root)
        try await history.save(HistoryEntry(textContent: "one", ocrConfidence: 1, captureMode: "area"))
        try await history.save(HistoryEntry(textContent: "two", ocrConfidence: 1, captureMode: "window"))

        let notificationCount = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: HistoryActor.imagesDidChange,
            object: history,
            queue: nil
        ) { _ in
            notificationCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await history.clear()

        let observedCount = notificationCount.withLock { $0 }
        let remainingCount = await history.count()
        #expect(observedCount == 1)
        #expect(remainingCount == 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".history-notification-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
