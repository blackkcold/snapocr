import Foundation

/// A screenshot's stable identity and history linkage in the current shelf session.
public struct ScreenshotShelfEntry: Equatable, Sendable {
    /// Stable identity assigned when the screenshot completes.
    public let captureID: UUID

    /// Monotonically increasing sequence assigned at screenshot completion.
    public let completionSequence: UInt64

    /// The linked persisted history record, when saving to history succeeds.
    public var historyID: UUID?

    init(captureID: UUID, completionSequence: UInt64, historyID: UUID? = nil) {
        self.captureID = captureID
        self.completionSequence = completionSequence
        self.historyID = historyID
    }
}

/// Ordered, bounded metadata for the screenshots retained in one app session.
public struct ScreenshotShelfState: Equatable, Sendable {
    /// The configured number of visible screenshot entries.
    public private(set) var limit: Int

    /// Current entries in display order. New captures enter at the front; users may reorder them.
    public private(set) var entries: [ScreenshotShelfEntry]

    /// Creates an empty shelf and clamps its capacity to the supported range.
    ///
    /// - Parameter limit: Requested capacity. Values outside 1...6 are clamped.
    public init(limit: Int = 3) {
        self.limit = Self.clampedLimit(limit)
        entries = []
    }

    /// Inserts a completed screenshot and returns any oldest entries evicted by the limit.
    ///
    /// Re-inserting an existing capture ID is idempotent and does not change its order.
    ///
    /// - Parameters:
    ///   - captureID: Identity assigned to this capture.
    ///   - completionSequence: Monotonically increasing capture-completion sequence.
    /// - Returns: IDs of entries removed to satisfy the capacity limit.
    @discardableResult
    public mutating func insert(captureID: UUID, completionSequence: UInt64) -> [UUID] {
        guard !entries.contains(where: { $0.captureID == captureID }) else { return [] }

        let entry = ScreenshotShelfEntry(
            captureID: captureID,
            completionSequence: completionSequence
        )
        entries.insert(entry, at: 0)
        return evictOldestUntilWithinLimit()
    }

    /// Changes the capacity immediately and returns the oldest entries removed.
    ///
    /// Increasing the capacity does not restore entries previously removed from the shelf.
    ///
    /// - Parameter limit: Requested capacity. Values outside 1...6 are clamped.
    /// - Returns: IDs of entries removed to satisfy the new capacity.
    @discardableResult
    public mutating func setLimit(_ limit: Int) -> [UUID] {
        self.limit = Self.clampedLimit(limit)
        return evictOldestUntilWithinLimit()
    }

    /// Moves an existing capture to a new display index without changing its identity.
    ///
    /// The destination is clamped to the current entry range. Moving an entry to the front or
    /// back does not affect eviction: capacity always removes the smallest completion sequence.
    ///
    /// - Parameters:
    ///   - captureID: Existing shelf entry to move.
    ///   - destinationIndex: Final zero-based index after the move.
    public mutating func move(captureID: UUID, to destinationIndex: Int) {
        guard let sourceIndex = entries.firstIndex(where: { $0.captureID == captureID }),
              !entries.isEmpty else { return }
        let destination = min(max(destinationIndex, 0), entries.count - 1)
        guard sourceIndex != destination else { return }
        let entry = entries.remove(at: sourceIndex)
        entries.insert(entry, at: destination)
    }

    /// Links a persisted history record to an existing shelf identity without reordering it.
    ///
    /// - Parameters:
    ///   - captureID: Existing shelf entry to update.
    ///   - historyID: Persisted history record identifier.
    public mutating func linkHistory(captureID: UUID, historyID: UUID) {
        guard let index = entries.firstIndex(where: { $0.captureID == captureID }) else { return }
        entries[index].historyID = historyID
    }

    /// Removes shelf entries whose linked history records are no longer present.
    ///
    /// Unsaved entries are retained, and the relative order of remaining entries is unchanged.
    ///
    /// - Parameter existingHistoryIDs: The IDs currently owned by history.
    /// - Returns: Capture IDs removed because their linked history record disappeared.
    @discardableResult
    public mutating func reconcileHistory(existingHistoryIDs: Set<UUID>) -> [UUID] {
        let removedIDs = entries.compactMap { entry -> UUID? in
            guard let historyID = entry.historyID,
                  !existingHistoryIDs.contains(historyID) else { return nil }
            return entry.captureID
        }
        let removedSet = Set(removedIDs)
        entries.removeAll { removedSet.contains($0.captureID) }
        return removedIDs
    }

    /// Removes one shelf entry without affecting its persisted history record.
    ///
    /// - Parameter captureID: Entry to remove.
    public mutating func remove(captureID: UUID) {
        entries.removeAll { $0.captureID == captureID }
    }

    /// Removes all entries and returns their identities for session-asset cleanup.
    ///
    /// - Returns: IDs of entries that were in the shelf.
    public mutating func clear() -> [UUID] {
        let removed = entries.map(\.captureID)
        entries.removeAll(keepingCapacity: true)
        return removed
    }

    private mutating func evictOldestUntilWithinLimit() -> [UUID] {
        var evicted: [UUID] = []
        while entries.count > limit,
              let oldestIndex = entries.indices.min(by: {
                  entries[$0].completionSequence < entries[$1].completionSequence
              }) {
            evicted.append(entries.remove(at: oldestIndex).captureID)
        }
        return evicted
    }

    private static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 6)
    }
}
