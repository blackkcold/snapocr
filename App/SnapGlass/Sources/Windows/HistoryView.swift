import SwiftUI
import AppKit
import HistoryCore
import ImageIO

struct HistoryView: View {
    @EnvironmentObject private var captureViewModel: CaptureViewModel
    @State private var entries: [HistoryEntry] = []
    @State private var searchQuery = ""
    @State private var isClearing = false
    @State private var selectedEntryID: HistoryEntry.ID?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private let history = HistoryActor.shared

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if entries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .toolbar { toolbarContent }
        .task { await loadEntries() }
        .background(.ultraThinMaterial)
        .alert("History Error", isPresented: errorAlertBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error"))
        }
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

    // MARK: - Empty State

    private var emptyStateTitle: LocalizedStringKey {
        if history == nil {
            return "History unavailable"
        }
        return searchQuery.isEmpty ? "No captures yet" : "No results found"
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

    // MARK: - Entry List

    private var entryList: some View {
        List(entries, selection: $selectedEntryID) { entry in
            HistoryRow(entry: entry)
                .onTapGesture(count: 2) {
                    Task { await openInEditor(entry) }
                }
                .contextMenu { contextMenu(for: entry) }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await deleteEntry(entry) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        }
        .listStyle(.plain)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        Button {
            Task { await openInEditor(entry) }
        } label: {
            Label("Open in Editor", systemImage: "pencil.and.outline")
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
                        Text(String(format: String(localized: "This will permanently delete all %d history entries."), entries.count))
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadEntries() async {
        guard let history else {
            entries = []
            return
        }

        do {
            if searchQuery.isEmpty {
                let count = await history.count()
                entries = try await history.recent(limit: max(count, 1))
            } else {
                entries = try await history.search(query: searchQuery)
            }
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEntry(_ entry: HistoryEntry) async {
        guard let history else { return }

        do {
            try await history.delete(id: entry.id)
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openInEditor(_ entry: HistoryEntry) async {
        guard let history else { return }
        do {
            guard let data = try await history.imageData(for: entry.id) else {
                errorMessage = String(localized: "The original screenshot is no longer available. It may have been removed by the retention policy.")
                return
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                errorMessage = String(localized: "The stored screenshot could not be decoded.")
                return
            }
            captureViewModel.openEditor(with: image, captureMode: entry.captureMode)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAll() async {
        guard let history else { return }

        do {
            try await history.clear()
            entries = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private enum ExportFormat {
        case json, csv, plaintext
    }
    
    private func exportHistory(format: ExportFormat) async {
        guard let history else { return }

        let panel = NSSavePanel()
        
        switch format {
        case .json:
            panel.nameFieldStringValue = "snapglass-history.json"
            panel.allowedContentTypes = [.json]
        case .csv:
            panel.nameFieldStringValue = "snapglass-history.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        case .plaintext:
            panel.nameFieldStringValue = "snapglass-history.txt"
            panel.allowedContentTypes = [.plainText]
        }
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        do {
            let historyFormat: HistoryExportFormat
            switch format {
            case .json:
                historyFormat = .json
            case .csv:
                historyFormat = .csv
            case .plaintext:
                historyFormat = .plainText
            }

            let data = try await history.export(ids: [], format: historyFormat)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let entry: HistoryEntry

    @State private var thumbnailImage: NSImage?

    private let history = HistoryActor.shared

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 4) {
                textPreview
                metadata
            }
        }
        .padding(.vertical, 4)
        .task { await loadThumbnail() }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: entryThumbnailIcon)
                        .foregroundColor(.secondary)
                }
        }
    }

    private var entryThumbnailIcon: String {
        switch entry.captureMode {
        case "area": return "rectangle.dashed"
        case "window": return "macwindow"
        case "fullscreen": return "display"
        case "scroll": return "arrow.up.arrow.down"
        default: return "doc.viewfinder"
        }
    }

    // MARK: - Text Preview

    private var textPreview: some View {
        Text(entry.textContent.isEmpty ? LocalizedStringKey("No text detected") : LocalizedStringKey(entry.textContent))
            .lineLimit(2)
            .font(.body)
            .foregroundColor(entry.textContent.isEmpty ? .secondary : .primary)
    }

    // MARK: - Metadata

    private var metadata: some View {
        HStack(spacing: 8) {
            Label(entry.timestamp.formatted(date: .abbreviated, time: .shortened),
                  systemImage: "clock")
                .font(.caption)
                .foregroundColor(.secondary)

            if !entry.captureMode.isEmpty {
                Label(entry.captureMode.capitalized, systemImage: "camera")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if entry.isFavourite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
        }
    }

    // MARK: - Load Thumbnail

    private func loadThumbnail() async {
        guard let history else { return }

        guard let data = try? await history.thumbnailData(for: entry.id),
              let image = NSImage(data: data)
        else { return }
        thumbnailImage = image
    }
}
