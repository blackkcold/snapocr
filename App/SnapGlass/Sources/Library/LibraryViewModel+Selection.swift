import Foundation
import LibraryCore

@MainActor
extension LibraryViewModel {
    // MARK: - Section state

    func selectSection(_ newSection: LibrarySection) {
        section = newSection
        selectedItemID = nil
        cancelSelection()
        if newSection == .colors {
            Task { await loadColors() }
        }
        if newSection == .recentlyDeleted {
            Task { await loadTrash() }
        }
        switch newSection {
        case .all, .favourites:
            viewMode = .list
        case .screenshots, .audio, .video:
            viewMode = .grid
        case .colors, .recoverable:
            break
        case .recentlyDeleted:
            viewMode = .list
        }
    }

    func count(for section: LibrarySection) -> Int {
        switch section {
        case .all:
            return allItems.count
        case .favourites:
            return allItems.filter { $0.isFavourite }.count
        case .screenshots:
            return screenshots.count
        case .audio:
            return recordingGroups.filter { $0.kind == .audio }.count
        case .video:
            return recordingGroups.filter { $0.kind == .screen }.count
        case .colors:
            return colorEntries.count
        case .recoverable:
            return recoverable.count
        case .recentlyDeleted:
            return trashEntries.count
        }
    }

    // MARK: - Selection

    var selectionItems: [LibraryCore.LibraryItem] {
        allItems.filter { selection.contains($0.id) }
    }

    var selectionCount: Int { selection.count }
    var selectionByteSize: Int64 {
        selectionItems.reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
    }
    var hasScreenshotSelection: Bool {
        selectionItems.contains { $0.mediaKind == .screenshot }
    }
    var hasRecordingSelection: Bool {
        selectionItems.contains { $0.recordingGroup != nil }
    }

    func handleClick(_ item: LibraryCore.LibraryItem) {
        if isSelecting {
            toggleSelection(item.id)
            return
        }
        selectedItemID = item.id
        isInspectorPresented = true
    }

    func toggleSelection(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        if selection.isEmpty {
            isSelecting = false
        }
    }

    func beginSelection() {
        isSelecting = true
        if let selectedItemID {
            selection.insert(selectedItemID)
        }
    }

    func cancelSelection() {
        selection.removeAll()
        isSelecting = false
    }

    func selectAllVisible() {
        isSelecting = true
        selection = Set(filteredItems.map(\.id))
    }

    func toggleExpanded(_ group: LibraryRecordingGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }
}
