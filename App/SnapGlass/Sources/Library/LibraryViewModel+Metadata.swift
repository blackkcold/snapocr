import Foundation
import HistoryCore
import LibraryCore

@MainActor
extension LibraryViewModel {
    // MARK: - Favourites and rename

    func toggleFavourite(_ item: LibraryCore.LibraryItem) async {
        switch item {
        case .screenshot(var entry):
            guard let history = HistoryActor.shared else { return }
            do {
                if let updated = try await history.setFavourite(
                    id: entry.id,
                    isFavourite: !entry.isFavourite
                ) {
                    if let index = screenshots.firstIndex(where: { $0.id == updated.id }) {
                        screenshots[index] = updated
                    }
                    showToast(
                        updated.isFavourite
                            ? AppLocalization.string("Added to favourites")
                            : AppLocalization.string("Removed from favourites")
                    )
                }
            } catch {
                showToast(error.localizedDescription, type: .error)
            }
        case .recording(let group):
            await metadataStore.setFavourite(!group.isFavourite, for: group.sessionID)
            if let index = recordingGroups.firstIndex(where: { $0.id == group.id }) {
                recordingGroups[index] = recordingGroups[index].withFavourite(!group.isFavourite)
            }
            showToast(
                group.isFavourite
                    ? AppLocalization.string("Removed from favourites")
                    : AppLocalization.string("Added to favourites")
            )
        }
    }

    func setFavouriteForSelection(_ isFavourite: Bool) async {
        let items = selectionItems
        guard !items.isEmpty else { return }
        if let history = HistoryActor.shared {
            for entry in items.compactMap(\.screenshot) where entry.isFavourite != isFavourite {
                _ = try? await history.setFavourite(id: entry.id, isFavourite: isFavourite)
            }
        }
        for group in items.compactMap(\.recordingGroup) where group.isFavourite != isFavourite {
            await metadataStore.setFavourite(isFavourite, for: group.sessionID)
        }
        screenshots = await loadScreenshots()
        recordingGroups = recordingGroups.map { group in
            guard items.contains(where: { $0.id == group.id }) else { return group }
            return group.withFavourite(isFavourite)
        }
        showToast(
            isFavourite
                ? AppLocalization.string("Added to favourites")
                : AppLocalization.string("Removed from favourites")
        )
    }

    func renameSelectedRecording(to newTitle: String) async {
        guard let group = selectedRecordingGroup else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let manualGroupID = group.manualGroupID {
            _ = await metadataStore.updateGroup(
                id: manualGroupID,
                title: trimmed.isEmpty ? nil : trimmed
            )
        } else {
            await metadataStore.setDisplayName(
                trimmed.isEmpty ? nil : trimmed,
                for: group.sessionID
            )
        }
        if let index = recordingGroups.firstIndex(where: { $0.id == group.id }) {
            recordingGroups[index] = recordingGroups[index].withTitle(trimmed)
        }
        showToast(AppLocalization.string("Name updated"))
    }

    // MARK: - Tags and note

    func updateTags(for group: LibraryRecordingGroup, text: String) async {
        let tags =
            text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for sessionID in group.memberSessionIDs {
            await metadataStore.setTags(tags, for: sessionID)
        }
        if let index = recordingGroups.firstIndex(where: { $0.id == group.id }) {
            recordingGroups[index] = recordingGroups[index].withTags(tags)
        }
        showToast(AppLocalization.string("Tags updated"))
    }

    func updateNote(for group: LibraryRecordingGroup, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmed.isEmpty ? nil : trimmed
        for sessionID in group.memberSessionIDs {
            await metadataStore.setNote(note, for: sessionID)
        }
        if let index = recordingGroups.firstIndex(where: { $0.id == group.id }) {
            recordingGroups[index] = recordingGroups[index].withNote(note)
        }
        showToast(AppLocalization.string("Note updated"))
    }
}
