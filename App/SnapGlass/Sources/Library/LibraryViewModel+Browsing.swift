import Foundation
import HistoryCore
import LibraryCore

@MainActor
extension LibraryViewModel {
    private static let screenshotPageSize = 200

    // MARK: - Loading

    func load() async {
        if screenshots.isEmpty, recordingGroups.isEmpty {
            isLoading = true
        }
        isRefreshing = true
        defer {
            isLoading = false
            isRefreshing = false
        }

        async let entries = loadScreenshots()
        async let snapshot = recordingService.scan()
        let loadedScreenshots = await entries
        let loadedSnapshot = await snapshot

        screenshots = loadedScreenshots
        recordingGroups = loadedSnapshot.groups
        sessionGroups = loadedSnapshot.sessionGroups
        offlineRoots = loadedSnapshot.offlineRoots
        await loadTrash()
        if let colorHistory = ColorHistoryStore.shared {
            let count = await colorHistory.count()
            colorEntries = await colorHistory.recent(limit: max(count, 1))
        }

        if !didPruneThumbnailCache {
            didPruneThumbnailCache = true
            Task { await thumbnailService.pruneCache() }
        }

        let recoverableTask = Task { [weak self] in
            guard let self else { return }
            let scanned = await RecordingRecoveryService.shared.scan(
                roots: RecordingExportRoots.current()
            )
            self.recoverable = scanned
        }
        _ = recoverableTask

        if let pendingDeepLink {
            handleDeepLink(pendingDeepLink)
        }
    }

    func handleDeepLink(_ request: LibraryDeepLink.Request) {
        guard let sessionID = request.sessionID,
            let group = recordingGroups.first(where: { $0.sessionID == sessionID })
        else {
            pendingDeepLink = request
            return
        }
        pendingDeepLink = nil
        section = group.kind == .audio ? .audio : .video
        selectedItemID = group.id
        expandedGroupIDs.insert(group.id)
        isInspectorPresented = true
        if request.action == .merge {
            isShowingMergeSheet = true
        }
    }

    func refresh() async {
        await load()
    }

    func refreshScreenshots() async {
        screenshots = await loadScreenshots()
    }

    func searchTextChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshScreenshots()
        }
    }

    var canLoadMoreScreenshots: Bool {
        screenshotHasMore && !isLoadingMoreScreenshots
    }

    func loadMoreScreenshots() async {
        guard screenshotHasMore, !isLoadingMoreScreenshots,
            let history = HistoryActor.shared
        else { return }
        isLoadingMoreScreenshots = true
        defer { isLoadingMoreScreenshots = false }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let next: [HistoryEntry]
            if query.isEmpty {
                next = try await history.page(
                    offset: screenshotOffset,
                    limit: Self.screenshotPageSize
                )
            } else {
                next = try await history.searchPage(
                    query: query,
                    offset: screenshotOffset,
                    limit: Self.screenshotPageSize
                )
            }
            screenshots.append(contentsOf: next)
            screenshotOffset += next.count
            screenshotHasMore = next.count == Self.screenshotPageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadScreenshots() async -> [HistoryEntry] {
        guard let history = HistoryActor.shared else {
            errorMessage = AppLocalization.string("History storage is unavailable.")
            return []
        }
        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let page: [HistoryEntry]
            if query.isEmpty {
                page = try await history.page(
                    offset: 0,
                    limit: Self.screenshotPageSize
                )
            } else {
                page = try await history.searchPage(
                    query: query,
                    offset: 0,
                    limit: Self.screenshotPageSize
                )
            }
            screenshotOffset = page.count
            screenshotHasMore = page.count == Self.screenshotPageSize
            return page
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    // MARK: - Derived collections

    var allItems: [LibraryCore.LibraryItem] {
        screenshots.map(LibraryCore.LibraryItem.screenshot) + recordingGroups.map(LibraryCore.LibraryItem.recording)
    }

    var filteredItems: [LibraryCore.LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return
            allItems
            .filter { item in
                switch section {
                case .all:
                    break
                case .favourites:
                    guard item.isFavourite else { return false }
                case .screenshots:
                    guard item.mediaKind == .screenshot else { return false }
                case .audio:
                    guard item.mediaKind == .audio else { return false }
                case .video:
                    guard item.mediaKind == .video else { return false }
                case .colors, .recoverable, .recentlyDeleted:
                    return false
                }

                if filter.favouritesOnly, !item.isFavourite { return false }

                if case .screenshot = item,
                    filter.duration != .any || filter.status != .any
                {
                    return false
                }

                let status = item.recordingGroup?.state.filterValue ?? .complete
                let location = item.recordingGroup?.roots.first?.path
                guard
                    filter.matches(
                        date: item.date,
                        duration: item.duration ?? 0,
                        status: status,
                        isFavourite: item.isFavourite,
                        locationPath: location
                    )
                else { return false }

                guard !query.isEmpty else { return true }
                return item.searchText.localizedCaseInsensitiveContains(query)
            }
            .sorted(by: sortComparator)
    }

    var daySections: [LibraryDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredItems) { item in
            calendar.startOfDay(for: item.date)
        }
        let days = grouped.keys.sorted { lhs, rhs in
            sort == .oldest ? lhs < rhs : lhs > rhs
        }
        return days.map { day in
            LibraryDaySection(
                id: "\(day.timeIntervalSince1970)",
                date: day,
                items: (grouped[day] ?? []).sorted(by: sortComparator)
            )
        }
    }

    var selectedItem: LibraryCore.LibraryItem? {
        guard let selectedItemID else { return nil }
        return allItems.first { $0.id == selectedItemID }
    }

    var selectedRecordingGroup: LibraryRecordingGroup? {
        selectedItem?.recordingGroup
    }

    var selectedScreenshot: HistoryEntry? {
        selectedItem?.screenshot
    }

    // MARK: - Sorting

    private func sortComparator(_ lhs: LibraryCore.LibraryItem, _ rhs: LibraryCore.LibraryItem) -> Bool {
        switch sort {
        case .newest:
            return lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date > rhs.date
        case .oldest:
            return lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        case .longest:
            return (lhs.duration ?? 0) == (rhs.duration ?? 0)
                ? lhs.date > rhs.date
                : (lhs.duration ?? 0) > (rhs.duration ?? 0)
        case .largest:
            return (lhs.byteSize ?? 0) == (rhs.byteSize ?? 0)
                ? lhs.date > rhs.date
                : (lhs.byteSize ?? 0) > (rhs.byteSize ?? 0)
        case .name:
            let left = itemTitle(lhs)
            let right = itemTitle(rhs)
            let result = left.localizedStandardCompare(right)
            return result == .orderedSame ? lhs.date > rhs.date : result == .orderedAscending
        }
    }

    private func itemTitle(_ item: LibraryCore.LibraryItem) -> String {
        switch item {
        case .screenshot(let entry):
            return entry.sourceWindowTitle ?? entry.sourceAppName ?? AppLocalization.string("Screenshot")
        case .recording(let group):
            return group.title.isEmpty
                ? (group.kind == .audio
                    ? AppLocalization.string("Audio Recording")
                    : AppLocalization.string("Screen Recording"))
                : group.title
        }
    }
}
