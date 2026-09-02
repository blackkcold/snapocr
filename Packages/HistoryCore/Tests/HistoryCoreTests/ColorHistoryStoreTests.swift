import Foundation
import SharedKit
import Testing

@testable import HistoryCore

struct ColorHistoryStoreTests {
  private func makeTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("snapglass-color-history-test-\(UUID().uuidString)")
  }

  private func makeColor(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> SampledColor {
    SampledColor(red: red, green: green, blue: blue, alpha: 255)
  }

  @Test func roundTripPersistsAcrossInstances() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ColorHistoryStore(baseURL: root)
    try await store.save(makeColor(255, 0, 0), source: .area)
    try await store.save(makeColor(0, 128, 255), source: .editor)

    let reloaded = try ColorHistoryStore(baseURL: root)
    let entries = await reloaded.recent(limit: 10)

    #expect(entries.count == 2)
    #expect(entries.first?.hexString == "#0080FF")
    #expect(entries.first?.source == .editor)
    #expect(entries.last?.hexString == "#FF0000")
  }

  @Test func dedupesSameColorAndMovesToFront() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ColorHistoryStore(baseURL: root)
    let first = makeColor(10, 20, 30)
    try await store.save(first, source: .area)
    try await store.save(makeColor(200, 200, 200), source: .editor)
    try await store.save(first, source: .editor)

    let entries = await store.recent(limit: 10)
    #expect(entries.count == 2)
    #expect(entries.first?.hexString == "#0A141E")
    #expect(entries.first?.source == .editor)
    #expect(entries.last?.hexString == "#C8C8C8")
  }

  @Test func evictsOldestBeyondConfiguredLimit() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    UserDefaults.standard.set(10, forKey: PreferenceKeys.colorHistoryMaxItems)
    defer { UserDefaults.standard.removeObject(forKey: PreferenceKeys.colorHistoryMaxItems) }

    let store = try ColorHistoryStore(baseURL: root)
    let oldest = makeColor(1, 1, 1)
    for index in 1...11 {
      try await store.save(makeColor(UInt8(index), UInt8(index), UInt8(index)), source: .area)
    }

    let entries = await store.recent(limit: 20)
    let count = await store.count()

    #expect(count == 10)
    #expect(!entries.contains { $0.hexString == oldest.hexString })
    #expect(entries.first?.hexString == "#0B0B0B")
  }

  @Test func clearRemovesAllEntriesAndPersists() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ColorHistoryStore(baseURL: root)
    try await store.save(makeColor(9, 9, 9), source: .editor)

    try await store.clear()
    let countAfterClear = await store.count()
    #expect(countAfterClear == 0)

    let reloaded = try ColorHistoryStore(baseURL: root)
    let entries = await reloaded.recent(limit: 10)
    #expect(entries.isEmpty)
  }

  @Test func deleteRemovesSingleEntry() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ColorHistoryStore(baseURL: root)
    try await store.save(makeColor(5, 5, 5), source: .area)
    try await store.save(makeColor(6, 6, 6), source: .area)
    let entries = await store.recent(limit: 10)

    try await store.delete(id: entries[0].id)
    let remaining = await store.recent(limit: 10)

    #expect(remaining.count == 1)
    #expect(remaining.first?.hexString == "#050505")
  }

  @Test func discardsCorruptedFileOnInitWithoutCrashing() async throws {
    let root = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try ColorHistoryStore(baseURL: root)
    try await store.save(makeColor(7, 7, 7), source: .editor)

    let colorsFile = root
      .appendingPathComponent("History/v2/colors/colors.enc")
    try Data("corrupted-garbage".utf8).write(to: colorsFile)

    let reloaded = try ColorHistoryStore(baseURL: root)
    let entries = await reloaded.recent(limit: 10)
    #expect(entries.isEmpty)

    try await reloaded.save(makeColor(8, 8, 8), source: .area)
    let recovered = try ColorHistoryStore(baseURL: root)
    let recoveredEntries = await recovered.recent(limit: 10)
    #expect(recoveredEntries.count == 1)
    #expect(recoveredEntries.first?.hexString == "#080808")
  }
}
