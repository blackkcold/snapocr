import Foundation
import Testing

@testable import HistoryCore

struct HistoryStorageV2Tests {
  @Test func initializesV2StorageWithoutTouchingLegacyHistory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("snapglass-history-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let legacyDirectory = root.appendingPathComponent("History/entries")
    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    let legacyMarker = legacyDirectory.appendingPathComponent("legacy.enc")
    try Data("legacy".utf8).write(to: legacyMarker)

    _ = try HistoryActor(baseURL: root)

    #expect(FileManager.default.fileExists(atPath: legacyMarker.path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("History/v2/entries").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Security/history-v2.key").path))
  }

  @Test func enforcesWholeEntryCountLimitAndPreservesFavourite() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("snapglass-history-limit-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = CleanupPolicy(
      maxEntries: 2,
      retentionDays: [.image: 30, .text: 30, .thumbnail: 30],
      maxCount: [.image: 2, .text: 2, .thumbnail: 2]
    )
    let history = try HistoryActor(cleanupPolicy: policy, baseURL: root)
    let favourite = HistoryEntry(
      timestamp: Date().addingTimeInterval(-300),
      textContent: "favourite",
      ocrConfidence: 1,
      captureMode: "area",
      isFavourite: true
    )
    let older = HistoryEntry(
      timestamp: Date().addingTimeInterval(-200),
      textContent: "older",
      ocrConfidence: 1,
      captureMode: "area"
    )
    let newest = HistoryEntry(
      timestamp: Date(),
      textContent: "newest",
      ocrConfidence: 1,
      captureMode: "area"
    )

    try await history.save(favourite)
    try await history.save(older)
    try await history.save(newest)

    let loadedFavourite = try await history.load(id: favourite.id)
    let loadedOlder = try await history.load(id: older.id)
    let loadedNewest = try await history.load(id: newest.id)
    let count = await history.count()
    #expect(loadedFavourite != nil)
    #expect(loadedOlder == nil)
    #expect(loadedNewest != nil)
    #expect(count == 2)
  }

  @Test func removesEntireExpiredNonFavouriteEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("snapglass-history-age-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let policy = CleanupPolicy(
      maxEntries: 10,
      retentionDays: [.image: 7, .text: 7, .thumbnail: 7],
      maxCount: [.image: 10, .text: 10, .thumbnail: 10]
    )
    let history = try HistoryActor(cleanupPolicy: policy, baseURL: root)
    let expired = HistoryEntry(
      timestamp: Date().addingTimeInterval(-8 * 86_400),
      textContent: "expired",
      ocrConfidence: 1,
      captureMode: "area"
    )

    try await history.save(expired)

    let loadedExpired = try await history.load(id: expired.id)
    let count = await history.count()
    #expect(loadedExpired == nil)
    #expect(count == 0)
  }
}
