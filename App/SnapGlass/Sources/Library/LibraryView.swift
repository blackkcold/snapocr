import AppKit
import CaptureCore
import HistoryCore
import LibraryCore
import SwiftUI

// MARK: - Root

struct LibraryView: View {
    @EnvironmentObject private var captureViewModel: CaptureViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var viewModel = LibraryViewModel()
    @StateObject private var rootWatcher = LibraryRootWatcher()
    @ObservedObject private var deepLink = LibraryDeepLink.shared
    @State private var showInspectorSheet = false

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 1_000
            HStack(alignment: .top, spacing: DS.Space.s10) {
                LibrarySidebar(viewModel: viewModel)

                VStack(spacing: 0) {
                    LibraryHeader(
                        viewModel: viewModel,
                        isWide: isWide,
                        openInspector: {
                            if isWide {
                                viewModel.isInspectorPresented.toggle()
                            } else {
                                showInspectorSheet = true
                            }
                        }
                    )
                    Divider().opacity(0.55)
                    if captureViewModel.recordingStatus != .idle {
                        LibraryLiveRecordingBanner(captureViewModel: captureViewModel)
                    }
                    if !viewModel.offlineRoots.isEmpty {
                        HStack(spacing: DS.Space.s8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(
                                AppLocalization.string(
                                    "%@ recording folder(s) offline",
                                    String(viewModel.offlineRoots.count)
                                )
                            )
                            .font(DS.Typography.caption)
                            Spacer()
                            Button("Retry") {
                                Task { await viewModel.refresh() }
                            }
                            .frame(minHeight: 24)
                        }
                        .padding(.horizontal, DS.Space.s12)
                        .padding(.vertical, DS.Space.s6)
                        .background(
                            Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .padding(.horizontal, DS.Space.s12)
                        .padding(.bottom, DS.Space.s6)
                        .help(viewModel.offlineRoots.joined(separator: "\n"))
                    }
                    LibraryContent(
                        viewModel: viewModel,
                        captureViewModel: captureViewModel,
                        isInspectorSheetPresented: showInspectorSheet
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isWide, viewModel.isInspectorPresented, let item = viewModel.selectedItem {
                    LibraryInspector(
                        viewModel: viewModel,
                        item: item,
                        captureViewModel: captureViewModel
                    )
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(DS.Space.s12)
            .frame(minWidth: 720, minHeight: 520)
            .background {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .animation(.easeInOut(duration: DS.Motion.base), value: viewModel.isInspectorPresented)
            .sheet(isPresented: $showInspectorSheet) {
                if let item = viewModel.selectedItem {
                    LibraryInspector(
                        viewModel: viewModel,
                        item: item,
                        captureViewModel: captureViewModel
                    )
                    .frame(minWidth: 420, minHeight: 520)
                }
            }
            .sheet(isPresented: $viewModel.isShowingDeleteSheet) {
                LibraryDeleteSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingExportSheet) {
                LibraryExportSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingMergeSheet) {
                LibraryMergeSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingRecoverableSheet) {
                LibraryRecoverableSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingStorageSheet) {
                LibraryStorageSheet(viewModel: viewModel)
            }
        }
        .task { await viewModel.load() }
        .onAppear {
            rootWatcher.start(
                roots: RecordingExportRoots.current().map(\.root)
            )
        }
        .onDisappear {
            rootWatcher.stop()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .recordingLibraryDidChange)
        ) { _ in
            Task { await viewModel.refresh() }
        }
        .onAppear {
            if let request = deepLink.consume() {
                viewModel.handleDeepLink(request)
            }
        }
        .onChange(of: deepLink.request) { request in
            guard let request else { return }
            _ = deepLink.consume()
            viewModel.handleDeepLink(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryActor.imagesDidChange)) { _ in
            Task { await viewModel.refreshScreenshots() }
        }
        .toast(message: $viewModel.toastMessage, edge: .bottom)
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Library")
                .font(DS.Typography.title)
                .padding(.horizontal, DS.Space.s8)
                .padding(.top, DS.Space.s4)

            sidebarSection("Library")
            row(.all, icon: "square.grid.2x2", title: "All")
            row(.favourites, icon: "star", title: "Favourites")

            sidebarSection("Types")
            row(.screenshots, icon: "photo", title: "Screenshots")
            row(.audio, icon: "waveform", title: "Audio")
            row(.video, icon: "rectangle.dashed.badge.record", title: "Video")

            sidebarSection("Other")
            row(.colors, icon: "paintpalette", title: "Colors")
            row(.recentlyDeleted, icon: "trash", title: "Recently Deleted")

            Button {
                viewModel.isShowingRecoverableSheet = true
            } label: {
                HStack(spacing: DS.Space.s8) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .frame(width: 16)
                    Text("Incomplete")
                    Spacer(minLength: 2)
                    let count = viewModel.recoverable.count
                    if count > 0 {
                        Text("\(count)")
                            .font(DS.Typography.captionStrong)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
                }
                .font(DS.Typography.body)
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 7)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Storage")
                    Spacer()
                    Text(librarySize(viewModel.recordingGroups.reduce(Int64(0)) { $0 + $1.byteSize }))
                        .monospacedDigit()
                }
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.14))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(4, geo.size.width * storageFraction))
                    }
                }
                .frame(height: 4)

                Text("\(viewModel.recordingSessionCount) recordings")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)

                Button("Manage Storage…") {
                    viewModel.isShowingStorageSheet = true
                }
                .font(DS.Typography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, DS.Space.s8)
            .padding(.bottom, DS.Space.s6)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(DS.Space.s8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var storageFraction: Double {
        let used = Double(viewModel.recordingGroups.reduce(Int64(0)) { $0 + $1.byteSize })
        let cap = 10.0 * 1_024 * 1_024 * 1_024
        return min(1, used / cap)
    }

    private func sidebarSection(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(DS.Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.s8)
            .padding(.top, DS.Space.s10)
            .padding(.bottom, 1)
    }

    private func row(
        _ section: LibrarySection,
        icon: String,
        title: LocalizedStringKey
    ) -> some View {
        let selected = viewModel.section == section
        return Button {
            viewModel.selectSection(section)
        } label: {
            HStack(spacing: DS.Space.s8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 2)
                Text("\(viewModel.count(for: section))")
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .font(DS.Typography.body)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .background(
                selected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.sidebar.\(section.rawValue)")
        .padding(.horizontal, 3)
    }
}

// MARK: - Header

private struct LibraryHeader: View {
    @ObservedObject var viewModel: LibraryViewModel
    let isWide: Bool
    let openInspector: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(sectionTitle)
                        .font(DS.Typography.display)
                    Text(countText)
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                searchField

                Menu {
                    Picker("Date", selection: $viewModel.filter.dateRange) {
                        Text("Any time").tag(LibraryDateRange.any)
                        Text("Today").tag(LibraryDateRange.today)
                        Text("Last 7 days").tag(LibraryDateRange.last7Days)
                        Text("Last 30 days").tag(LibraryDateRange.last30Days)
                    }
                    Picker("Duration", selection: $viewModel.filter.duration) {
                        Text("Any duration").tag(LibraryDurationFilter.any)
                        Text("Under 1 min").tag(LibraryDurationFilter.underOneMinute)
                        Text("1–10 min").tag(LibraryDurationFilter.oneToTenMinutes)
                        Text("10–60 min").tag(LibraryDurationFilter.tenToSixtyMinutes)
                        Text("Over 1 hour").tag(LibraryDurationFilter.overOneHour)
                    }
                    Picker("Status", selection: $viewModel.filter.status) {
                        Text("Any status").tag(LibraryStatusFilter.any)
                        Text("Complete").tag(LibraryStatusFilter.complete)
                        Text("Partial").tag(LibraryStatusFilter.partial)
                        Text("Offline").tag(LibraryStatusFilter.offline)
                    }
                    Toggle("Favourites only", isOn: $viewModel.filter.favouritesOnly)
                    Divider()
                    Button("Clear filters") {
                        viewModel.filter = LibraryFilter()
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Picker("Sort", selection: $viewModel.sort) {
                        Text("Newest first").tag(LibrarySort.newest)
                        Text("Oldest first").tag(LibrarySort.oldest)
                        Text("Longest first").tag(LibrarySort.longest)
                        Text("Largest first").tag(LibrarySort.largest)
                        Text("Name").tag(LibrarySort.name)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if viewModel.section != .colors,
           viewModel.section != .recoverable,
           viewModel.section != .recentlyDeleted {
                    Picker("View", selection: $viewModel.viewMode) {
                        Image(systemName: "list.bullet").tag(LibraryViewMode.list)
                        Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 74)

                    Button(viewModel.isSelecting ? "Done" : "Select") {
                        if viewModel.isSelecting {
                            viewModel.cancelSelection()
                        } else {
                            viewModel.beginSelection()
                        }
                    }
                    .accessibilityIdentifier("library.select")
                    .frame(minHeight: 28)
                }

                if isWide {
                    Button(action: openInspector) {
                        Image(systemName: "sidebar.right")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help("Toggle inspector")
                    .disabled(viewModel.selectedItem == nil)
                }

                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.top, DS.Space.s10)
            .padding(.bottom, DS.Space.s7)

            if viewModel.filter.isActive || !viewModel.searchText.isEmpty {
                activeFilterChips
                    .padding(.horizontal, DS.Space.s12)
                    .padding(.bottom, DS.Space.s7)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search title, date or OCR text", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(DS.Typography.body)
                .accessibilityIdentifier("library.search")
                .onChange(of: viewModel.searchText) { _ in
                    viewModel.searchTextChanged()
                }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .frame(minWidth: 150, idealWidth: 220, maxWidth: 260)
    }

    private var activeFilterChips: some View {
        HStack(spacing: 5) {
            if viewModel.filter.favouritesOnly {
                chip("Favourites")
            }
            if viewModel.filter.dateRange != .any {
                chip(dateFilterLabel)
            }
            if viewModel.filter.duration != .any {
                chip(durationFilterLabel)
            }
            if viewModel.filter.status != .any {
                chip(statusFilterLabel)
            }
            if !viewModel.searchText.isEmpty {
                chip("\"\(viewModel.searchText)\"")
            }
            Button("Clear") {
                viewModel.filter = LibraryFilter()
                viewModel.searchText = ""
            }
            .font(DS.Typography.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Spacer()
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    private var sectionTitle: LocalizedStringKey {
        switch viewModel.section {
        case .all: "All"
        case .favourites: "Favourites"
        case .screenshots: "Screenshots"
        case .audio: "Audio"
        case .video: "Video"
        case .colors: "Colors"
        case .recoverable: "Incomplete Recordings"
        case .recentlyDeleted: "Recently Deleted"
        }
    }

    private var countText: String {
        let count = viewModel.filteredItems.count
        let total = viewModel.count(for: viewModel.section)
        if viewModel.section == .colors {
            return AppLocalization.string("%@ colors", String(viewModel.colorEntries.count))
        }
        if viewModel.section == .recoverable {
            return AppLocalization.string("%@ recoverable", String(viewModel.recoverable.count))
        }
        if viewModel.section == .recentlyDeleted {
            return AppLocalization.string("%@ items", String(viewModel.trashEntries.count))
        }
        if count == total {
            return AppLocalization.string("%@ items", String(count))
        }
        return AppLocalization.string("%@ of %@ items", String(count), String(total))
    }

    private var dateFilterLabel: String {
        switch viewModel.filter.dateRange {
        case .any: ""
        case .today: AppLocalization.string("Today")
        case .last7Days: AppLocalization.string("Last 7 days")
        case .last30Days: AppLocalization.string("Last 30 days")
        case .custom: AppLocalization.string("Custom range")
        }
    }

    private var durationFilterLabel: String {
        switch viewModel.filter.duration {
        case .any: ""
        case .underOneMinute: AppLocalization.string("Under 1 min")
        case .oneToTenMinutes: AppLocalization.string("1–10 min")
        case .tenToSixtyMinutes: AppLocalization.string("10–60 min")
        case .overOneHour: AppLocalization.string("Over 1 hour")
        }
    }

    private var statusFilterLabel: String {
        switch viewModel.filter.status {
        case .any: ""
        case .complete: AppLocalization.string("Complete")
        case .partial: AppLocalization.string("Partial")
        case .offline: AppLocalization.string("Offline")
        }
    }
}

// MARK: - Content

private struct LibraryContent: View {
    @ObservedObject var viewModel: LibraryViewModel
    let captureViewModel: CaptureViewModel
    let isInspectorSheetPresented: Bool
    @FocusState private var isGridFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch viewModel.section {
                case .colors:
                    LibraryColorsView(viewModel: viewModel)
                case .recoverable:
                    LibraryRecoverableView(viewModel: viewModel)
                case .recentlyDeleted:
                    LibraryTrashView(viewModel: viewModel)
                default:
                    mediaContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isSelecting || !viewModel.selection.isEmpty {
                LibraryBatchBar(viewModel: viewModel)
                    .padding(.horizontal, DS.Space.s12)
                    .padding(.bottom, DS.Space.s12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        Group {
            if viewModel.isLoading, viewModel.allItems.isEmpty {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.allItems.isEmpty {
                LibraryEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Library unavailable",
                    message: LocalizedStringKey(error),
                    primaryTitle: "Retry",
                    primaryAction: { Task { await viewModel.refresh() } },
                    secondaryTitle: nil,
                    secondaryAction: nil
                )
            } else if viewModel.filteredItems.isEmpty {
                emptyState
            } else if viewModel.viewMode == .list {
                LibraryListView(
                    viewModel: viewModel,
                    captureViewModel: captureViewModel,
                    gridFocus: $isGridFocused
                )
            } else {
                LibraryGridView(
                    viewModel: viewModel,
                    captureViewModel: captureViewModel,
                    gridFocus: $isGridFocused
                )
            }
        }
        .background { commandShortcuts }
        .onChange(of: viewModel.selectedItemID) { selected in
            // Keyboard commands follow the row the user just clicked, but the
            // grid only takes focus on an explicit selection: the search field
            // keeps the keyboard until then.
            if selected != nil {
                isGridFocused = true
            }
        }
    }

    // MARK: - Keyboard commands

    private var commandContext: LibraryCommandContext {
        let hasSelection = viewModel.selectedItem != nil
        return LibraryCommandContext(
            hasSelection: hasSelection,
            visibleItemCount: viewModel.filteredItems.count,
            canOpen: hasSelection,
            canExport: hasSelection || !viewModel.selection.isEmpty,
            canDelete: hasSelection,
            canFavourite: hasSelection,
            isSelecting: viewModel.isSelecting,
            isSheetPresented: isInspectorSheetPresented
                || viewModel.isShowingDeleteSheet
                || viewModel.isShowingExportSheet
                || viewModel.isShowingMergeSheet
                || viewModel.isShowingRecoverableSheet
                || viewModel.isShowingStorageSheet
        )
    }

    /// Shortcut bindings come from `LibraryCommand` so the table the tests
    /// exercise is the one the window actually uses. They stay disabled until
    /// the grid has focus, which keeps ⌘A, space and escape out of the search
    /// field and the inspector's text fields.
    private var commandShortcuts: some View {
        ForEach(LibraryCommand.allCases, id: \.self) { command in
            Button(AppLocalization.string(command.titleKey)) {
                perform(command)
            }
            .keyboardShortcut(
                keyEquivalent(for: command),
                modifiers: eventModifiers(for: command)
            )
            .disabled(
                !isGridFocused
                    || !LibraryCommandRouter.isEnabled(command, context: commandContext)
            )
            .hidden()
        }
    }

    private func perform(_ command: LibraryCommand) {
        guard LibraryCommandRouter.isEnabled(command, context: commandContext) else { return }
        switch command {
        case .preview:
            quickLookSelected()
        case .open:
            openSelectedItem()
        case .export:
            if !viewModel.isSelecting || viewModel.selection.isEmpty {
                guard let id = viewModel.selectedItemID else { return }
                viewModel.selection = [id]
                viewModel.isSelecting = true
            }
            viewModel.isShowingExportSheet = true
        case .delete:
            viewModel.requestDeleteSelection()
        case .favourite:
            guard let item = viewModel.selectedItem else { return }
            Task { await viewModel.toggleFavourite(item) }
        case .selectAll:
            viewModel.selectAllVisible()
        case .cancel:
            viewModel.cancelSelection()
        }
    }

    private func keyEquivalent(for command: LibraryCommand) -> KeyEquivalent {
        switch command {
        case .preview: return " "
        case .open: return .return
        case .export: return "e"
        case .delete: return .delete
        case .favourite: return "f"
        case .selectAll: return "a"
        case .cancel: return .escape
        }
    }

    private func eventModifiers(for command: LibraryCommand) -> EventModifiers {
        var result: EventModifiers = []
        for modifier in command.modifiers {
            switch modifier {
            case .command: result.insert(.command)
            case .shift: result.insert(.shift)
            case .option: result.insert(.option)
            case .control: result.insert(.control)
            }
        }
        return result
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem else { return }
        switch item {
        case .screenshot(let entry):
            Task { await viewModel.openScreenshot(entry, using: captureViewModel) }
        case .recording(let group):
            viewModel.openRecording(group)
        }
    }

    private func quickLookSelected() {
        guard let item = viewModel.selectedItem else { return }
        Task {
            let urls = await viewModel.quickLookURLs(for: item)
            guard !urls.isEmpty else {
                viewModel.showToast(
                    AppLocalization.string("Preview unavailable"),
                    type: .error
                )
                return
            }
            LibraryQuickLookCoordinator.shared.show(urls)
        }
    }

    private var emptyState: some View {
        let searching = !viewModel.searchText.isEmpty || viewModel.filter.isActive
        if searching {
            return LibraryEmptyState(
                icon: "magnifyingglass",
                title: "No results",
                message: "Try a different search or clear the filters.",
                primaryTitle: "Clear search",
                primaryAction: {
                    viewModel.searchText = ""
                    viewModel.filter = LibraryFilter()
                },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        }
        switch viewModel.section {
        case .audio:
            return LibraryEmptyState(
                icon: "waveform",
                title: "No audio recordings",
                message: "Audio recordings appear here as soon as they finish.",
                primaryTitle: "Record audio",
                primaryAction: { Task { await captureViewModel.startDefaultAudioRecording() } },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        case .video:
            return LibraryEmptyState(
                icon: "rectangle.dashed.badge.record",
                title: "No video recordings",
                message: "Screen recordings appear here when they are published.",
                primaryTitle: "Record screen",
                primaryAction: { captureViewModel.startRecording() },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        case .favourites:
            return LibraryEmptyState(
                icon: "star",
                title: "No favourites yet",
                message: "Star a screenshot, audio or video to keep it here.",
                primaryTitle: "Show all",
                primaryAction: { viewModel.selectSection(.all) },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        default:
            return LibraryEmptyState(
                icon: "clock.arrow.circlepath",
                title: "No history yet",
                message: "Screenshots, audio and video will appear here.",
                primaryTitle: "Record audio",
                primaryAction: { Task { await captureViewModel.startDefaultAudioRecording() } },
                secondaryTitle: "Record screen",
                secondaryAction: { captureViewModel.startRecording() }
            )
        }
    }
}

// MARK: - Batch bar

private struct LibraryBatchBar: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        HStack(spacing: DS.Space.s8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.string("%@ selected", String(viewModel.selectionCount)))
                    .font(DS.Typography.captionStrong)
                Text(librarySize(viewModel.selectionByteSize))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.leading, 4)

            Spacer(minLength: 6)

            Button {
                Task {
                    let allFavourite = viewModel.selectionItems.allSatisfy(\.isFavourite)
                    await viewModel.setFavouriteForSelection(!allFavourite)
                }
            } label: {
                Label("Favourite", systemImage: "star")
            }
            .buttonStyle(.borderless)

            Button {
                viewModel.isShowingExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)

            if viewModel.canGroupSelection {
                Button {
                    Task { await viewModel.groupSelection() }
                } label: {
                    Label("Group", systemImage: "rectangle.3.group")
                }
                .buttonStyle(.borderless)
            }

            Button {
                viewModel.isShowingMergeSheet = true
            } label: {
                Label("Merge", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canMergeSelection)
            .help(viewModel.canMergeSelection
                  ? "Merge the selected recording"
                  : "Select one complete recording with multiple segments")

            Button(role: .destructive) {
                viewModel.requestDeleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.borderless)

            Button("Cancel") {
                viewModel.cancelSelection()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}

// MARK: - Empty state

private struct LibraryEmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let primaryTitle: LocalizedStringKey?
    let primaryAction: (() -> Void)?
    let secondaryTitle: LocalizedStringKey?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Space.s12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(DS.Typography.title)
            Text(message)
                .font(DS.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: DS.Space.s10) {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(.borderedProminent)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.s20)
    }
}

// MARK: - Colors

private struct LibraryColorsView: View {
    @ObservedObject var viewModel: LibraryViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: DS.Space.s12, alignment: .top),
    ]

    var body: some View {
        if viewModel.colorEntries.isEmpty {
            LibraryEmptyState(
                icon: "paintpalette",
                title: "No colors yet",
                message: "Colors sampled with the eyedropper appear here.",
                primaryTitle: nil,
                primaryAction: nil,
                secondaryTitle: nil,
                secondaryAction: nil
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.s12) {
                    ForEach(viewModel.colorEntries) { entry in
                        ColorHistoryCard(entry: entry) {
                            viewModel.copyColor(entry)
                        } onDelete: {
                            Task { await viewModel.deleteColor(entry) }
                        }
                    }
                }
                .padding(DS.Space.s12)
            }
        }
    }
}

// MARK: - Recoverable

private struct LibraryRecoverableView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        if viewModel.recoverable.isEmpty {
            LibraryEmptyState(
                icon: "checkmark.circle",
                title: "Nothing to recover",
                message: "Interrupted recordings that still have media appear here.",
                primaryTitle: nil,
                primaryAction: nil,
                secondaryTitle: nil,
                secondaryAction: nil
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s8) {
                    ForEach(viewModel.recoverable) { recording in
                        HStack(spacing: DS.Space.s10) {
                            Image(systemName: recording.kind == .audio
                                  ? "waveform" : "rectangle.dashed.badge.record")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recording.kind == .audio
                                     ? "Incomplete audio recording"
                                     : "Incomplete screen recording")
                                    .font(DS.Typography.bodyStrong)
                                Text(recording.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(DS.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Save to library") {
                                Task { await viewModel.recover(recording) }
                            }
                            Button("Move to Trash") {
                                Task { await viewModel.discard(recording) }
                            }
                        }
                        .padding(DS.Space.s10)
                        .background(
                            Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                }
                .padding(DS.Space.s12)
            }
        }
    }
}
