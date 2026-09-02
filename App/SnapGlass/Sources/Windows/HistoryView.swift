import SwiftUI
import AppKit
import HistoryCore
import ImageIO

struct HistoryView: View {
    private enum Segment: String, CaseIterable, Identifiable {
        case screenshots
        case colors

        var id: String { rawValue }
    }

    @EnvironmentObject private var captureViewModel: CaptureViewModel
    @State private var segment: Segment = .screenshots
    @State private var entries: [HistoryEntry] = []
    @State private var colorEntries: [ColorHistoryEntry] = []
    @State private var searchQuery = ""
    @State private var colorFilter = ""
    @State private var isClearing = false
    @State private var isClearingColors = false
    @State private var selectedEntryID: HistoryEntry.ID?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var toastMessage: ToastMessage?

    private let history = HistoryActor.shared
    private let colorHistory = ColorHistoryStore.shared

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
                if entries.isEmpty {
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
                            Text(String(format: String(localized: "This will permanently delete all %d history entries."), entries.count))
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
                        Text(String(format: String(localized: "This will permanently delete all %d color entries."), colorEntries.count))
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadEntries() async {
        switch segment {
        case .screenshots:
            await loadScreenshotEntries()
        case .colors:
            await loadColorEntries()
        }
    }

    private func loadScreenshotEntries() async {
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

    private func loadColorEntries() async {
        guard let colorHistory else {
            colorEntries = []
            return
        }

        do {
            let count = await colorHistory.count()
            colorEntries = try await colorHistory.recent(limit: max(count, 1))
        } catch {
            colorEntries = []
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

    private func deleteColorEntry(_ entry: ColorHistoryEntry) async {
        guard let colorHistory else { return }

        do {
            try await colorHistory.delete(id: entry.id)
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyColor(_ entry: ColorHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.hexString, forType: .string)
        let toast = ToastMessage(
            message: String(
                format: NSLocalizedString(
                    "Color %@ copied",
                    comment: "History color copy success"
                ),
                entry.hexString
            ),
            type: .success
        )
        toastMessage = toast
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toastMessage?.id == toast.id {
                toastMessage = nil
            }
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
            // 清空截图历史时同步清空取色历史，避免 colors/ 目录残留。
            if let colorHistory {
                try? await colorHistory.clear()
                colorEntries = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearColors() async {
        guard let colorHistory else { return }

        do {
            try await colorHistory.clear()
            colorEntries = []
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

// MARK: - Color History Card

private struct ColorHistoryCard: View {
    let entry: ColorHistoryEntry
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(
                        red: Double(entry.color.red) / 255,
                        green: Double(entry.color.green) / 255,
                        blue: Double(entry.color.blue) / 255
                    ))
                    .frame(height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.hexString)
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text(entry.rgbString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: entry.source == .area ? "rectangle.dashed" : "eyedropper")
                            .font(.caption2)
                        Text(entry.source == .area ? "Area" : "Editor")
                            .font(.caption2)
                        Spacer()
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
