import Foundation

extension HistoryActor {
    /// Returns a page of the newest-first history.
    ///
    /// The current store still materializes its in-memory dictionary before
    /// slicing; the page boundary is a presentation/memory boundary. A future
    /// on-disk index can replace the backing store without changing this API.
    public func page(offset: Int, limit: Int) async throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let ordered = orderedEntries()
        let start = min(max(0, offset), ordered.count)
        let end = min(start + limit, ordered.count)
        return Array(ordered[start..<end])
    }

    /// Paged search with the same newest-first ordering.
    public func searchPage(
        query: String,
        offset: Int,
        limit: Int
    ) async throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered: [HistoryEntry]
        if trimmed.isEmpty {
            ordered = orderedEntries()
        } else {
            ordered = try await search(query: trimmed)
        }
        let start = min(max(0, offset), ordered.count)
        let end = min(start + limit, ordered.count)
        return Array(ordered[start..<end])
    }

    private func orderedEntries() -> [HistoryEntry] {
        allPersistedEntries().values.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp > rhs.timestamp
        }
    }
}
