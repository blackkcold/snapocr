import Foundation
import Testing

@testable import HistoryCore

struct HistoryPresentationTests {
  @Test func filtersAndSortsGroupsInBothDirections() {
    let entries = (0..<4).map { index in
      HistoryEntry(
        timestamp: Date(timeIntervalSince1970: Double(index)),
        textContent: "OCR", ocrConfidence: 1, captureMode: "area", isFavourite: index % 2 == 0)
    }
    for newest in [true, false] {
      for first in [true, false] {
        let result = HistoryPresentation.entries(
          entries, filter: .all,
          favouriteOrder: first ? .first : .last, newestFirst: newest)
        let expected =
          first
          ? (newest ? [2, 0, 3, 1] : [0, 2, 1, 3])
          : (newest ? [3, 1, 2, 0] : [1, 3, 0, 2])
        #expect(result.map(\.id) == expected.map { entries[$0].id })
      }
    }
    #expect(
      HistoryPresentation.entries(
        entries, filter: .favourites,
        favouriteOrder: .first, newestFirst: true
      ).allSatisfy { $0.isFavourite })
    #expect(
      HistoryPresentation.entries(
        entries, filter: .unfavourited,
        favouriteOrder: .first, newestFirst: true
      ).allSatisfy { !$0.isFavourite })
  }

  @Test func gridColumnsStayBoundedAndTiesAreStable() {
    #expect(HistoryPresentation.columnCount(for: 0) == 1)
    #expect(HistoryPresentation.columnCount(for: 540) == 3)
    #expect(HistoryPresentation.columnCount(for: 720) == 4)
    #expect(HistoryPresentation.columnCount(for: 900) == 5)
    #expect(HistoryPresentation.columnCount(for: 2_000) == 5)
    let date = Date()
    let entries = (0..<4).map { _ in
      HistoryEntry(timestamp: date, textContent: "", ocrConfidence: 1, captureMode: "area")
    }
    let result = HistoryPresentation.entries(entries, filter: .all, favouriteOrder: .first, newestFirst: true)
    #expect(result.map { $0.id.uuidString } == entries.map { $0.id.uuidString }.sorted())
  }

  @Test func favouriteUpdateSurvivesReloadAndPreservesColdEntries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryActor(baseURL: root)
    let entry = HistoryEntry(textContent: "keep OCR", ocrConfidence: 1, captureMode: "area")
    let other = HistoryEntry(textContent: "other", ocrConfidence: 1, captureMode: "window")
    try await history.save(entry)
    try await history.save(other)
    let cold = try HistoryActor(baseURL: root)
    await cold.evictHotCacheForTest()
    let updated = try await cold.setFavourite(id: entry.id, isFavourite: true)
    #expect(updated?.isFavourite == true)
    #expect(updated?.textContent == "keep OCR")
    #expect(await cold.count() == 2)
    let reloaded = try HistoryActor(baseURL: root)
    #expect(try await reloaded.load(id: entry.id)?.isFavourite == true)
    #expect(try await reloaded.setFavourite(id: entry.id, isFavourite: false)?.isFavourite == false)
    #expect(try await reloaded.setFavourite(id: UUID(), isFavourite: true) == nil)
  }
}

extension HistoryActor {
  fileprivate func evictHotCacheForTest() { entries = [:] }
}
