import SwiftUI
import AppKit
import HistoryCore
import ImageIO

struct HistoryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case screenshots
        case colors

        var id: String { rawValue }
    }

    @EnvironmentObject var captureViewModel: CaptureViewModel
    @State var segment: Segment = .screenshots
    @State var entries: [HistoryEntry] = []
    @State var colorEntries: [ColorHistoryEntry] = []
    @State var searchQuery = ""
    @State private var colorFilter = ""
    @State private var isClearing = false
    @State private var isClearingColors = false
    @State private var selectedEntryID: HistoryEntry.ID?
    @State private var favouriteFilter: HistoryPresentation.Filter = .all
    @State private var favouriteOrder: HistoryPresentation.FavouriteOrder = .first
    @State private var newestFirst = true
    @State var thumbnailSizes: [UUID: CGSize] = [:]
    @State var updatingFavourites: Set<UUID> = []
    @State var screenshotLoadID = UUID()
    @State var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State var toastMessage: ToastMessage?

    let history = HistoryActor.shared
    let colorHistory = ColorHistoryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("History segment", selection: $segment) {
                ForEach(Segment.allCases) { item in
                    switch item {
                    case .screenshots: Text("Screenshots").tag(item)
                    case .colors: Text("Colors").tag(item)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            switch segment {
            case .screenshots:
                searchBar
                historyFilters
                if visibleEntries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            case .colors:
                colorFilterBar
                if filteredColorEntries.isEmpty {
                    colorEmptyState
                } else {
                    colorGrid
                }
            }
        }
        .toolbar { toolbarContent }
        .task { await loadEntries() }
        .onChange(of: segment) { _ in
            searchTask?.cancel()
            Task { await loadEntries() }
        }
        .background(.ultraThinMaterial)
        .alert("History Error", isPresented: errorAlertBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error"))
        }
        .toast(message: $toastMessage, edge: .bottom)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search history…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.body)
                .onChange(of: searchQuery) { _ in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await loadEntries()
                    }
                }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var colorFilterBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search colors…", text: $colorFilter)
                .textFieldStyle(.plain)
                .font(.body)
            if !colorFilter.isEmpty {
                Button {
                    colorFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyStateTitle: LocalizedStringKey {
        if history == nil {
            return "History unavailable"
        }
        return searchQuery.isEmpty && favouriteFilter == .all ? "No captures yet" : "No results found"
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(emptyStateTitle)
                .font(.title3)
                .foregroundColor(.secondary)

            if history == nil {
                Text("Check the application support folder permissions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if !searchQuery.isEmpty {
                Text("Try a different search term")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var colorEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "paintpalette")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(colorEmptyStateTitle)
                .font(.title3)
                .foregroundColor(.secondary)

            if colorHistory == nil {
                Text("Check the application support folder permissions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if !colorFilter.isEmpty {
                Text("Try a different search term")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var colorEmptyStateTitle: LocalizedStringKey {
        if colorHistory == nil {
            return "History unavailable"
        }
        return colorFilter.isEmpty ? "No colors captured yet" : "No matching colors"
    }

    // MARK: - Entry List

    private var entryList: some View {
        GeometryReader { geometry in
            let count = HistoryPresentation.columnCount(for: geometry.size.width - 32)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: count),
                          alignment: .leading, spacing: 20) {
                    ForEach(visibleEntries) { entry in
                        HistoryScreenshotCard(
                            entry: entry, imageSize: thumbnailSizes[entry.id],
                            isSelected: selectedEntryID == entry.id,
                            isUpdatingFavourite: updatingFavourites.contains(entry.id),
                            onSelect: { selectedEntryID = entry.id },
                            onOpen: {
                                selectedEntryID = entry.id
                                Task { await openInEditor(entry) }
                            },
                            onFavourite: { Task { await toggleFavourite(entry) } }
                        )
                        .contextMenu { contextMenu(for: entry) }
                    }
                }
                .padding(16)
            }
        }
    }

    private var visibleEntries: [HistoryEntry] {
        HistoryPresentation.entries(entries, filter: favouriteFilter,
                                    favouriteOrder: favouriteOrder, newestFirst: newestFirst)
    }

    private var historyFilters: some View {
        HStack {
            Menu {
                Picker("Show", selection: $favouriteFilter) {
                    Text("All screenshots").tag(HistoryPresentation.Filter.all)
                    Text("Favourites only").tag(HistoryPresentation.Filter.favourites)
                    Text("Unfavourited only").tag(HistoryPresentation.Filter.unfavourited)
                }
                Picker("Favourite order", selection: $favouriteOrder) {
                    Text("Favourites first").tag(HistoryPresentation.FavouriteOrder.first)
                    Text("Favourites last").tag(HistoryPresentation.FavouriteOrder.last)
                }
                Picker("Time order", selection: $newestFirst) {
                    Text("Newest first").tag(true)
                    Text("Oldest first").tag(false)
                }
            } label: {
                Label("Filter and sort", systemImage: "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            Spacer()
            Text("\(visibleEntries.count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Color Grid

    private var filteredColorEntries: [ColorHistoryEntry] {
        let query = colorFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return colorEntries }
        return colorEntries.filter { $0.hexString.lowercased().contains(query.lowercased()) }
    }

    private var colorGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: .infinity), spacing: 12)],
                spacing: 12
            ) {
                ForEach(filteredColorEntries) { entry in
                    ColorHistoryCard(entry: entry) {
                        copyColor(entry)
                    } onDelete: {
                        Task { await deleteColorEntry(entry) }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        Button {
            Task { await toggleFavourite(entry) }
        } label: {
            Label(entry.isFavourite ? "Remove favourite" : "Add favourite",
                  systemImage: entry.isFavourite ? "star.slash" : "star")
        }
        .disabled(updatingFavourites.contains(entry.id))

        Button {
            Task { await openInEditor(entry) }
        } label: {
            Label("Open in Editor", systemImage: "pencil.and.outline")
        }

        if entry.canRestoreOriginal {
            Button {
                Task { await restoreOriginal(entry) }
            } label: {
                Label("Restore Original Image", systemImage: "arrow.uturn.backward.circle")
            }
        }

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.textContent, forType: .string)
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            Task { await deleteEntry(entry) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            switch segment {
            case .screenshots:
                if !entries.isEmpty {
                    HStack {
                        Menu {
                            Button("Export as JSON") {
                                Task { await exportHistory(format: .json) }
                            }
                            Button("Export as CSV") {
                                Task { await exportHistory(format: .csv) }
                            }
                            Button("Export as Plaintext") {
                                Task { await exportHistory(format: .plaintext) }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            isClearing = true
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                        .alert("Clear All History?", isPresented: $isClearing) {
                            Button("Cancel", role: .cancel) {}
                            Button("Clear", role: .destructive) {
                                Task { await clearAll() }
                            }
                        } message: {
                            Text(
                                String(
                                    format: String(localized: "This will permanently delete all %d history entries."),
                                    entries.count
                                )
                            )
                        }
                    }
                }
            case .colors:
                if !colorEntries.isEmpty {
                    Button(role: .destructive) {
                        isClearingColors = true
                    } label: {
                        Label("Clear Colors", systemImage: "trash")
                    }
                    .alert("Clear Color History?", isPresented: $isClearingColors) {
                        Button("Cancel", role: .cancel) {}
                        Button("Clear", role: .destructive) {
                            Task { await clearColors() }
                        }
                    } message: {
                        Text(
                            String(
                                format: String(localized: "This will permanently delete all %d color entries."),
                                colorEntries.count
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

}
