import Foundation
import Testing

@testable import HistoryCore

@Suite("History paging")
struct HistoryPagingTests {
    @Test("Pages are newest-first and stable")
    func pagesAreStable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryPaging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryActor(baseURL: root)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<3 {
            try await history.save(
                HistoryEntry(
                    timestamp: base.addingTimeInterval(Double(index)),
                    textContent: "entry \(index)",
                    ocrConfidence: 1,
                    captureMode: "area"
                ))
        }

        let first = try await history.page(offset: 0, limit: 2)
        let second = try await history.page(offset: 2, limit: 2)
        #expect(first.count == 2)
        #expect(second.count == 1)
        #expect(first[0].textContent == "entry 2")
        #expect(first[1].textContent == "entry 1")
        #expect(second[0].textContent == "entry 0")
    }

    @Test("Search pages use the same ordering")
    func searchPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryPagingSearch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryActor(baseURL: root)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (index, text) in ["alpha", "beta", "alpha"].enumerated() {
            try await history.save(
                HistoryEntry(
                    timestamp: base.addingTimeInterval(Double(index)),
                    textContent: text,
                    ocrConfidence: 1,
                    captureMode: "area"
                ))
        }

        let first = try await history.searchPage(query: "alpha", offset: 0, limit: 1)
        let second = try await history.searchPage(query: "alpha", offset: 1, limit: 1)
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].textContent == "alpha")
        #expect(second[0].textContent == "alpha")
        #expect(first[0].timestamp > second[0].timestamp)
    }
}
