import AppKit
import HistoryCore

/// History reconciliation for the screenshot shelf.
///
/// Kept in its own file because the shelf manager sits at the project's
/// 1200-line source limit and this block is cohesive on its own.
@MainActor
extension ScreenshotShelfManager {
    func reconcileHistory() async {
        guard let history = HistoryActor.shared else { return }
        let historyEntries = await history.allEntries()
        let entriesByID = Dictionary(uniqueKeysWithValues: historyEntries.map { ($0.id, $0) })
        let removedIDs = state.reconcileHistory(existingHistoryIDs: Set(entriesByID.keys))
        removeCards(for: removedIDs)
        scheduleAssetRemoval(for: removedIDs)

        for entry in state.entries {
            guard let historyID = entry.historyID,
                let historyEntry = entriesByID[historyID]
            else { continue }
            updateHistoryCard(
                captureID: entry.captureID,
                historyID: historyID,
                pixelWidth: historyEntry.pixelWidth,
                pixelHeight: historyEntry.pixelHeight
            )
            await refreshHistoryThumbnail(
                captureID: entry.captureID,
                historyID: historyID,
                from: history
            )
            await refreshDragExportIfNeeded(
                captureID: entry.captureID,
                revision: historyEntry.imageRevision
            )
        }
        synchronizeCards()
        schedulePresentationUpdate()
    }

    func refreshHistoryCard(captureID: UUID, historyID: UUID) async {
        guard let history = HistoryActor.shared else { return }
        do {
            guard let historyEntry = try await history.load(id: historyID) else { return }
            updateHistoryCard(
                captureID: captureID,
                historyID: historyID,
                pixelWidth: historyEntry.pixelWidth,
                pixelHeight: historyEntry.pixelHeight
            )
            await refreshHistoryThumbnail(
                captureID: captureID,
                historyID: historyID,
                from: history
            )
            await refreshDragExport(captureID: captureID, revision: historyEntry.imageRevision)
            synchronizeCards()
            schedulePresentationUpdate()
        } catch {
            return
        }
    }

    private func updateHistoryCard(
        captureID: UUID,
        historyID: UUID,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) {
        guard
            state.entries.contains(where: {
                $0.captureID == captureID && $0.historyID == historyID
            }),
            var card = cardsByID[captureID]
        else { return }
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            card.imagePixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        }
        cardsByID[captureID] = card
    }

    private func refreshHistoryThumbnail(
        captureID: UUID,
        historyID: UUID,
        from history: HistoryActor
    ) async {
        guard
            state.entries.contains(where: {
                $0.captureID == captureID && $0.historyID == historyID
            })
        else {
            return
        }
        do {
            guard let data = try await history.thumbnailData(for: historyID) else { return }
            let thumbnailData = await Task.detached(priority: .utility) {
                ScreenshotShelfAssetEncoder.displayThumbnail(from: data)
            }.value
            guard let thumbnailData,
                state.entries.contains(where: {
                    $0.captureID == captureID && $0.historyID == historyID
                })
            else { return }
            await setThumbnail(thumbnailData, for: captureID)
        } catch {
            return
        }
    }

    /// Rebuilds the plaintext copy from the card's current bytes.
    private func refreshDragExport(captureID: UUID, revision: UUID?) async {
        dragExportStore.invalidate(captureID: captureID)
        guard let data = try? await originalData(for: captureID) else { return }
        await dragExportStore.prepare(
            captureID: captureID,
            data: data,
            sourceTypeIdentifier: ScreenshotShelfImageTypeIdentifier.identifier(for: data),
            revision: revision?.uuidString
        )
    }

    /// Rebuilds the plaintext copy only when the history revision changed.
    private func refreshDragExportIfNeeded(captureID: UUID, revision: UUID?) async {
        let revisionKey = revision?.uuidString
        if dragExportStore.artifact(for: captureID) != nil,
            dragExportStore.revision(for: captureID) == revisionKey {
            return
        }
        await refreshDragExport(captureID: captureID, revision: revision)
    }
}
