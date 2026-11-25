import AppKit
import CaptureCore
import Combine
import Foundation
import HistoryCore
import ImageIO
import LibraryCore
import UniformTypeIdentifiers

@MainActor
final class LibraryViewModel: ObservableObject {
    // MARK: - Navigation and presentation

    @Published var section: LibrarySection = .all
    @Published var searchText = ""
    @Published var filter = LibraryFilter()
    @Published var sort: LibrarySort = .newest
    @Published var viewMode: LibraryViewMode = .list
    @Published var selectedItemID: String?
    @Published var selection: Set<String> = []
    @Published var isSelecting = false
    @Published var expandedGroupIDs: Set<String> = []
    @Published var isInspectorPresented = false

    // MARK: - Data

    @Published private(set) var screenshots: [HistoryEntry] = []
    @Published private(set) var recordingGroups: [LibraryRecordingGroup] = []
    @Published private(set) var sessionGroups: [LibraryRecordingGroup] = []
    @Published private(set) var colorEntries: [ColorHistoryEntry] = []
    @Published private(set) var trashEntries: [HistoryTrashEntry] = []
    @Published private(set) var recoverable: [RecoverableRecording] = []
    @Published private(set) var offlineRoots: [String] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMoreScreenshots = false
    @Published private(set) var errorMessage: String?

    // MARK: - Sheets and feedback

    @Published var toastMessage: ToastMessage?
    @Published var isShowingDeleteSheet = false
    @Published var isShowingExportSheet = false
    @Published var isShowingMergeSheet = false
    @Published var isShowingRecoverableSheet = false
    @Published var isShowingStorageSheet = false
    @Published var isBusy = false
    @Published var isCleaningRecordings = false
    @Published var exportProgress: Double?
    @Published var exportMessage: String?
    @Published var mergeProgress: Double?
    @Published var mergeMessage: String?
    @Published var lastOutputURLs: [URL] = []

    // MARK: - Services

    private let metadataStore: RecordingLibraryStore
    private let recordingService: RecordingLibraryService
    private let thumbnailService: RecordingThumbnailService
    private let deletionService: RecordingDeletionService
    private let exportService: LibraryExportService
    private let mergeService: RecordingMergeService
    private let toastDeduplicator = ToastDeduplicator()
    private var thumbnails: [String: NSImage] = [:]
    private var searchTask: Task<Void, Never>?
    private var pendingDeepLink: LibraryDeepLink.Request?
    private var didPruneThumbnailCache = false
    private static let screenshotPageSize = 200
    private var screenshotOffset = 0
    private var screenshotHasMore = false

    init() {
        LibraryPaths.ensureDirectories()
        LibraryLocalization.setProvider { AppLocalization.string($0) }
        let metadataStore = RecordingLibraryStore(fileURL: LibraryPaths.metadataFileURL)
        self.metadataStore = metadataStore
        self.recordingService = RecordingLibraryService(
            roots: RecordingExportRoots.current().map {
                LibraryRoot(kind: $0.kind, root: $0.root, indexURL: $0.indexURL)
            },
            metadataStore: metadataStore
        )
        self.thumbnailService = RecordingThumbnailService()
        self.deletionService = RecordingDeletionService(metadataStore: metadataStore)
        self.exportService = LibraryExportService()
        self.mergeService = RecordingMergeService()
    }

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

    private func loadScreenshots() async -> [HistoryEntry] {
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
        return allItems
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
                   filter.duration != .any || filter.status != .any {
                    return false
                }

                let status = item.recordingGroup?.state.filterValue ?? .complete
                let location = item.recordingGroup?.roots.first?.path
                guard filter.matches(
                    date: item.date,
                    duration: item.duration ?? 0,
                    status: status,
                    isFavourite: item.isFavourite,
                    locationPath: location
                ) else { return false }

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
    var mergeGroups: [LibraryRecordingGroup] {
        let selectedGroups = selectionItems
            .compactMap(\.recordingGroup)
            .filter { $0.state == .complete && $0.segmentCount > 1 }
        if !selectedGroups.isEmpty {
            return selectedGroups.sorted { $0.startedAt < $1.startedAt }
        }
        if let selected = selectedRecordingGroup,
           selected.state == .complete,
           selected.segmentCount > 1 {
            return [selected]
        }
        return []
    }

    var canMergeSelection: Bool {
        let groups = mergeGroups
        guard let first = groups.first else { return false }
        if !selectionItems.isEmpty,
           selectionItems.contains(where: { $0.recordingGroup == nil }) {
            return false
        }
        return groups.allSatisfy { $0.kind == first.kind }
    }

    var canGroupSelection: Bool {
        let groups = selectionItems
            .compactMap(\.recordingGroup)
            .filter { !$0.isManualGroup }
        guard groups.count >= 2, let first = groups.first else { return false }
        return groups.allSatisfy { $0.kind == first.kind }
    }

    private func expandedMergeGroups(
        _ groups: [LibraryRecordingGroup]
    ) -> [LibraryRecordingGroup] {
        groups.flatMap { group in
            guard group.isManualGroup, !group.memberSessionIDs.isEmpty else {
                return [group]
            }
            let memberIDs = Set(group.memberSessionIDs)
            let members = sessionGroups.filter { memberIDs.contains($0.sessionID) }
            return members.isEmpty ? [group] : members
        }
    }

    func groupSelection() async {
        let groups = selectionItems
            .compactMap(\.recordingGroup)
            .filter { !$0.isManualGroup }
        guard groups.count >= 2, let first = groups.first,
              groups.allSatisfy({ $0.kind == first.kind })
        else { return }

        _ = await metadataStore.createGroup(
            title: nil,
            sessionIDs: groups.map(\.sessionID)
        )
        cancelSelection()
        await load()
        showToast(
            AppLocalization.string(
                "Grouped %@ recordings",
                String(groups.count)
            )
        )
    }

    func ungroup(_ group: LibraryRecordingGroup) async {
        guard let manualGroupID = group.manualGroupID else { return }
        await metadataStore.removeGroup(id: manualGroupID)
        selectedItemID = nil
        isInspectorPresented = false
        await load()
        showToast(AppLocalization.string("Ungrouped recordings"))
    }

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

    func updateTags(for group: LibraryRecordingGroup, text: String) async {
        let tags = text
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
              let image = NSImage(data: data) else { return nil }
        thumbnails[key] = image
        return image
    }

    // MARK: - Quick Look

    func quickLookURLs(for item: LibraryCore.LibraryItem) async -> [URL] {
        switch item {
        case .screenshot(let entry):
            guard let history = HistoryActor.shared,
                  let data = try? await history.imageData(for: entry.id)
            else { return [] }
            let directory = LibraryPaths.metadataFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("QuickLook", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                "\(entry.id.uuidString).\(imageExtension(for: data))"
            )
            do {
                try data.write(to: url, options: .atomic)
                return [url]
            } catch {
                return []
            }
        case .recording(let group):
            let urls = group.segments
                .flatMap(\.mediaURLs)
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                }
            if !urls.isEmpty { return urls }
            return group.mediaURL.map { [$0] } ?? []
        }
    }

    private func imageExtension(for data: Data) -> String {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?,
            let utType = UTType(type),
            let preferred = utType.preferredFilenameExtension
        else { return "png" }
        return preferred.lowercased() == "jpeg" ? "jpg" : preferred.lowercased()
    }

    // MARK: - Retention

    var recordingSessionCount: Int {
        sessionGroups.isEmpty ? recordingGroups.count : sessionGroups.count
    }

    private var retentionSourceGroups: [LibraryRecordingGroup] {
        sessionGroups.isEmpty ? recordingGroups : sessionGroups
    }

    var recordingLibraryByteSize: Int64 {
        retentionSourceGroups.reduce(Int64(0)) { $0 + $1.byteSize }
    }

    func retentionCandidateCount(olderThanDays days: Int) -> Int {
        RecordingRetentionPlanner.eligibleGroups(
            retentionSourceGroups,
            olderThanDays: days
        ).count
    }

    func cleanupRecordings(olderThanDays days: Int) async {
        let candidates = RecordingRetentionPlanner.eligibleGroups(
            retentionSourceGroups,
            olderThanDays: days
        )
        guard !candidates.isEmpty else {
            showToast(AppLocalization.string("No recordings are older than this."), type: .info)
            return
        }

        isCleaningRecordings = true
        defer { isCleaningRecordings = false }

        var deletedIDs = Set<String>()
        var failures: [String] = []
        for group in candidates {
            let report = await deletionService.delete(group)
            if report.deletedSessionCount > 0 {
                deletedIDs.insert(group.id)
            }
            failures.append(contentsOf: report.failures)
        }

        recordingGroups.removeAll { deletedIDs.contains($0.id) }
        await load()
        if failures.isEmpty {
            showToast(
                AppLocalization.string(
                    "Moved %@ recording(s) to the Trash",
                    String(deletedIDs.count)
                )
            )
        } else {
            showToast(
                failures.first ?? AppLocalization.string("Cleanup completed with errors"),
                type: .error
            )
        }
        isShowingStorageSheet = false
    }

    // MARK: - Export

    func exportSelection(options: LibraryExportOptions) async {
        let items = selectionItems.isEmpty ? filteredItems : selectionItems
        guard !items.isEmpty else {
            showToast(AppLocalization.string("Choose at least one item to export."), type: .error)
            return
        }
        isBusy = true
        exportProgress = 0
        exportMessage = AppLocalization.string("Preparing export…")
        defer {
            isBusy = false
            exportProgress = nil
            exportMessage = nil
        }

        do {
            let result = try await exportService.export(
                items: items,
                options: options,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.exportProgress = progress.fraction
                        self?.exportMessage = progress.message
                    }
                }
            )
            lastOutputURLs = result.outputURLs
            if let first = result.outputURLs.first {
                let message = result.warnings.first
                    ?? AppLocalization.string(
                        "Exported %@ file(s)",
                        String(result.outputURLs.count)
                    )
                showToast(
                    message,
                    type: result.warnings.isEmpty ? .success : .info,
                    actionLabel: AppLocalization.string("Show in Finder"),
                    action: {
                        NSWorkspace.shared.activateFileViewerSelecting([first])
                    }
                )
            } else {
                showToast(
                    result.failures.first ?? AppLocalization.string("Nothing was exported."),
                    type: .error
                )
            }
        } catch is CancellationError {
            showToast(AppLocalization.string("Export cancelled"), type: .info)
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    // MARK: - Merge

    func mergeSelected(destination: URL, outputTitle: String) async {
        let groups = expandedMergeGroups(mergeGroups)
        guard !groups.isEmpty else {
            showToast(AppLocalization.string("Choose one recording to merge."), type: .error)
            return
        }
        guard canMergeSelection else {
            showToast(AppLocalization.string("Only recordings of the same type can be merged together."), type: .error)
            return
        }
        isBusy = true
        mergeProgress = 0
        mergeMessage = AppLocalization.string("Preparing merge…")
        defer {
            isBusy = false
            mergeProgress = nil
            mergeMessage = nil
        }

        var outputs: [URL] = []
        var failures: [String] = []

        if groups.count > 1 {
            do {
                let result = try await mergeService.merge(
                    groups: groups,
                    destination: destination,
                    outputTitle: outputTitle,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            self?.mergeProgress = progress.fraction
                            self?.mergeMessage = progress.message
                        }
                    }
                )
                lastOutputURLs = result.outputURLs
                showToast(
                    AppLocalization.string(
                        "Merged into %@ file(s)",
                        String(result.outputURLs.count)
                    ),
                    actionLabel: AppLocalization.string("Show in Finder"),
                    action: {
                        NSWorkspace.shared.activateFileViewerSelecting(result.outputURLs)
                    }
                )
                return
            } catch RecordingMergeError.overLimit {
                // Too long for one file: fall through to per-group export.
            } catch {
                showToast(error.localizedDescription, type: .error)
                return
            }
        }

        for (index, group) in groups.enumerated() {
            let groupTitle = groups.count > 1
                ? "\(outputTitle) \(index + 1)"
                : outputTitle
            do {
                let result = try await mergeService.merge(
                    group: group,
                    destination: destination,
                    outputTitle: groupTitle,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            let base = Double(index) / Double(groups.count)
                            self?.mergeProgress = min(
                                1,
                                base + progress.fraction / Double(groups.count)
                            )
                            self?.mergeMessage = progress.message
                        }
                    }
                )
                outputs.append(contentsOf: result.outputURLs)
            } catch {
                failures.append(
                    "\(group.title.isEmpty ? AppLocalization.string("Recording") : group.title): \(error.localizedDescription)"
                )
            }
        }

        lastOutputURLs = outputs
        if outputs.isEmpty {
            showToast(
                failures.first ?? AppLocalization.string("Merge failed."),
                type: .error
            )
        } else {
            let message = failures.isEmpty
                ? AppLocalization.string("Merged into %@ file(s)", String(outputs.count))
                : AppLocalization.string(
                    "Merged %@ file(s); %@ item(s) failed.",
                    String(outputs.count),
                    String(failures.count)
                )
            showToast(
                message,
                type: failures.isEmpty ? .success : .info,
                actionLabel: AppLocalization.string("Show in Finder"),
                action: {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            )
        }
    }

    // MARK: - Opening and revealing

    func openScreenshot(_ entry: HistoryEntry, using captureViewModel: CaptureViewModel) async {
        guard let history = HistoryActor.shared,
              let data = try? await history.imageData(for: entry.id),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            showToast(AppLocalization.string("Could not open this screenshot."), type: .error)
            return
        }
        _ = captureViewModel.openEditor(
            with: cgImage,
            captureMode: entry.captureMode,
            sourceEntryID: entry.id,
            mockupStyle: HistoryMockupPresenter.style(from: entry)
        )
    }

    func openRecording(_ group: LibraryRecordingGroup) {
        guard let url = group.mediaURL else {
            showToast(AppLocalization.string("The recording file is unavailable."), type: .error)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ item: LibraryCore.LibraryItem) {
        switch item {
        case .screenshot:
            let folder = URL.appSupportDirectory
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("v2", isDirectory: true)
            NSWorkspace.shared.open(folder)
        case .recording(let group):
            let urls = group.segments.flatMap(\.mediaURLs)
            if urls.isEmpty, let firstRoot = group.roots.first {
                NSWorkspace.shared.open(firstRoot)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    // MARK: - Thumbnails

    func thumbnail(for item: LibraryCore.LibraryItem) async -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        let image: NSImage?
        switch item {
        case .screenshot(let entry):
            guard let history = HistoryActor.shared,
                  let data = try? await history.thumbnailData(for: entry.id)
            else { return nil }
            image = NSImage(data: data)
        case .recording(let group):
            guard let data = await thumbnailService.thumbnailData(for: group) else { return nil }
            image = NSImage(data: data)
        }
        if let image {
            thumbnails[item.id] = image
        }
        return image
    }

    // MARK: - Colors

    func loadColors() async {
        guard let store = ColorHistoryStore.shared else { return }
        let count = await store.count()
        colorEntries = await store.recent(limit: max(count, 1))
    }

    func copyColor(_ entry: ColorHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.hexString, forType: .string)
        showToast(AppLocalization.string("Color copied"))
    }

    func deleteColor(_ entry: ColorHistoryEntry) async {
        guard let store = ColorHistoryStore.shared else { return }
        try? await store.delete(id: entry.id)
        await loadColors()
    }

    // MARK: - Recoverable

    func recover(_ recording: RecoverableRecording) async {
        do {
            _ = try await RecordingRecoveryService.shared.recover(recording)
            recoverable.removeAll { $0.id == recording.id }
            await load()
            showToast(AppLocalization.string("Recovered recording added to your list."))
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    func discard(_ recording: RecoverableRecording) async {
        do {
            try await RecordingRecoveryService.shared.discard(recording)
            recoverable.removeAll { $0.id == recording.id }
            showToast(AppLocalization.string("Recording moved to the Trash."))
        } catch {
            showToast(error.localizedDescription, type: .error)
        }
    }

    // MARK: - Feedback

    func showToast(
        _ message: String,
        type: ToastType = .success,
        actionLabel: String? = nil,
        action: (@MainActor () -> Void)? = nil
    ) {
        guard toastDeduplicator.shouldPresent(message) else { return }
        let toast = ToastMessage(
            message: message,
            type: type,
            actionLabel: actionLabel,
            action: action
        )
        toastMessage = toast
        Task {
            try? await Task.sleep(for: .seconds(action == nil ? 3 : 6))
            if toastMessage?.id == toast.id {
                toastMessage = nil
            }
        }
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
