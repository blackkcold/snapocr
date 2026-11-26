import AppKit
import Foundation
import HistoryCore
import LibraryCore

@MainActor
extension LibraryViewModel {
    // MARK: - Delete

    func requestDeleteSelection() {
        guard !selection.isEmpty else { return }
        isShowingDeleteSheet = true
    }

    func performDeleteSelection() async {
        let items = selectionItems
        guard !items.isEmpty else { return }
        isBusy = true
        isShowingDeleteSheet = false
        defer { isBusy = false }

        let screenshotsToDelete = items.compactMap(\.screenshot)
        let recordingsToDelete = items.compactMap(\.recordingGroup)
        var failures: [String] = []

        var trashedScreenshots = 0
        if !screenshotsToDelete.isEmpty, let history = HistoryActor.shared {
            for entry in screenshotsToDelete {
                do {
                    try await history.moveToTrash(id: entry.id)
                    trashedScreenshots += 1
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            let deletedIDs = Set(screenshotsToDelete.map(\.id))
            screenshots.removeAll { deletedIDs.contains($0.id) }
        }

        for group in recordingsToDelete {
            let report = await deletionService.delete(group)
            failures.append(contentsOf: report.failures)
            if report.deletedSessionCount > 0 {
                recordingGroups.removeAll { $0.id == group.id }
            }
        }

        selectedItemID = nil
        isInspectorPresented = false
        cancelSelection()

        if trashedScreenshots > 0 {
            showToast(
                AppLocalization.string(
                    "%@ screenshot(s) moved to Recently Deleted",
                    String(trashedScreenshots)
                ),
                type: .info,
                actionLabel: AppLocalization.string("Show"),
                action: { [weak self] in
                    self?.selectSection(.recentlyDeleted)
                }
            )
        } else if recordingsToDelete.isEmpty {
            showToast(
                failures.first ?? AppLocalization.string("Deleted"),
                type: failures.isEmpty ? .success : .error
            )
        } else {
            showToast(
                failures.first ?? AppLocalization.string("Moved to the Trash"),
                type: failures.isEmpty ? .success : .error
            )
        }
    }

    // MARK: - Screenshot Trash

    func loadTrash() async {
        guard let history = HistoryActor.shared else {
            trashEntries = []
            return
        }
        trashEntries = (try? await history.trashEntries()) ?? []
    }

    func restoreTrashEntry(_ entry: HistoryTrashEntry) async {
        guard let history = HistoryActor.shared else { return }
        do {
            _ = try await history.restoreFromTrash(id: entry.id)
            await loadTrash()
            await refreshScreenshots()
            showToast(AppLocalization.string("Restored from Recently Deleted"))
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    func deleteTrashEntry(_ entry: HistoryTrashEntry) async {
        guard let history = HistoryActor.shared else { return }
        do {
            try await history.deleteTrashEntry(id: entry.id)
            await loadTrash()
            showToast(AppLocalization.string("Deleted permanently"))
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    func emptyTrash() async {
        guard let history = HistoryActor.shared else { return }
        do {
            try await history.emptyTrash()
            await loadTrash()
            showToast(AppLocalization.string("Recently Deleted emptied"))
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    func trashThumbnail(for entry: HistoryEntry) async -> NSImage? {
        let key = "trash:\(entry.id.uuidString)"
        if let cached = thumbnails[key] { return cached }
        guard let history = HistoryActor.shared,
            let data = try? await history.thumbnailData(for: entry.id),
            let image = NSImage(data: data)
        else { return nil }
        thumbnails[key] = image
        return image
    }
}
