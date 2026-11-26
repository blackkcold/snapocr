import AppKit
import CaptureCore
import Combine
import Foundation
import HistoryCore
import LibraryCore

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

    @Published var screenshots: [HistoryEntry] = []
    @Published var recordingGroups: [LibraryRecordingGroup] = []
    @Published var sessionGroups: [LibraryRecordingGroup] = []
    @Published var colorEntries: [ColorHistoryEntry] = []
    @Published var trashEntries: [HistoryTrashEntry] = []
    @Published var recoverable: [RecoverableRecording] = []
    @Published var offlineRoots: [String] = []
    @Published var isLoading = true
    @Published var isRefreshing = false
    @Published var isLoadingMoreScreenshots = false
    @Published var errorMessage: String?

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

    let metadataStore: RecordingLibraryStore
    let recordingService: RecordingLibraryService
    let thumbnailService: RecordingThumbnailService
    let deletionService: RecordingDeletionService
    let exportService: LibraryExportService
    let mergeService: RecordingMergeService
    private let toastDeduplicator = ToastDeduplicator()
    var thumbnails: [String: NSImage] = [:]

    // MARK: - Paging state

    var searchTask: Task<Void, Never>?
    var pendingDeepLink: LibraryDeepLink.Request?
    var didPruneThumbnailCache = false
    var screenshotOffset = 0
    var screenshotHasMore = false

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
}
