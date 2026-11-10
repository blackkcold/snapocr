import AppKit
import CaptureCore
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
            let historyStyle = HistoryMockupPresenter.style(from: historyEntry)
            if var card = cardsByID[entry.captureID],
               card.mockupStyle != historyStyle {
                card.mockupStyle = historyStyle
                cardsByID[entry.captureID] = card
                historyPresentationKeys[entry.captureID] = nil
            }
            updateHistoryCard(
                captureID: entry.captureID,
                historyID: historyID,
                pixelWidth: historyEntry.pixelWidth,
                pixelHeight: historyEntry.pixelHeight
            )
            await refreshHistoryPresentation(
                captureID: entry.captureID,
                historyID: historyID,
                revision: historyEntry.imageRevision,
                history: history
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
            await refreshHistoryPresentation(
                captureID: captureID,
                historyID: historyID,
                revision: historyEntry.imageRevision,
                history: history
            )
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

    /// Rebuilds both the card preview and the drag artifact from history.
    ///
    /// When the card has a style, the raw history image is re-rendered with that
    /// style. This is the step that used to overwrite a beautified card with the
    /// raw history thumbnail after `linkHistory`.
    private func refreshHistoryPresentation(
        captureID: UUID,
        historyID: UUID,
        revision: UUID?,
        history: HistoryActor
    ) async {
        guard
            let card = cardsByID[captureID],
            card.historyID == historyID,
            state.entries.contains(where: {
                $0.captureID == captureID && $0.historyID == historyID
            })
        else { return }

        let styleJSON = card.mockupStyle.flatMap {
            try? JSONEncoder().encode($0)
        }.flatMap {
            String(data: $0, encoding: .utf8)
        }
        let key = "\(revision?.uuidString ?? "nil")|\(styleJSON ?? "nil")"
        if historyPresentationKeys[captureID] == key,
           dragExportStore.artifact(for: captureID) != nil {
            return
        }

        if let style = card.mockupStyle {
            do {
                guard let rawData = try await history.imageData(for: historyID),
                      let raw = NSImage(data: rawData)?.cgImage(
                          forProposedRect: nil,
                          context: nil,
                          hints: nil
                      )
                else { return }
                guard let presented = await Task.detached(priority: .userInitiated, operation: {
                    MockupRenderer.render(raw, style: style)
                }).value,
                      let assets = await Task.detached(priority: .utility, operation: {
                          ScreenshotShelfAssetEncoder.encode(presented)
                      }).value
                else { return }

                await setThumbnail(assets.thumbnailData, for: captureID)
                dragExportStore.invalidate(captureID: captureID)
                await dragExportStore.prepare(
                    captureID: captureID,
                    data: assets.originalData,
                    sourceTypeIdentifier: "public.png",
                    revision: revision?.uuidString
                )
                historyPresentationKeys[captureID] = key
            } catch {
                return
            }
            return
        }

        do {
            guard let data = try await history.thumbnailData(for: historyID) else { return }
            let thumbnailData = await Task.detached(priority: .utility) {
                ScreenshotShelfAssetEncoder.displayThumbnail(from: data)
            }.value
            if let thumbnailData {
                await setThumbnail(thumbnailData, for: captureID)
            }
            guard let rawData = try await originalData(for: captureID) else { return }
            dragExportStore.invalidate(captureID: captureID)
            await dragExportStore.prepare(
                captureID: captureID,
                data: rawData,
                sourceTypeIdentifier: ScreenshotShelfImageTypeIdentifier.identifier(for: rawData),
                revision: revision?.uuidString
            )
            historyPresentationKeys[captureID] = key
        } catch {
            return
        }
    }
}
