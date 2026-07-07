import SwiftUI
import AppKit
import HistoryCore

struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []
    @State private var searchQuery = ""
    @State private var isClearing = false
    @State private var selectedEntryID: HistoryEntry.ID?

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
                    Task { await loadEntries() }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(searchQuery.isEmpty ? "No captures yet" : "No results found")
                .font(.title3)
                .foregroundColor(.secondary)

            if !searchQuery.isEmpty {
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
                        Text("This will permanently delete all \(entries.count) history entries.")
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadEntries() async {
        do {
            if searchQuery.isEmpty {
                entries = try await history.recent(limit: 200)
            } else {
                entries = try await history.search(query: searchQuery)
            }
        } catch {
            entries = []
        }
    }

    private func deleteEntry(_ entry: HistoryEntry) async {
        do {
            try await history.delete(id: entry.id)
            await loadEntries()
        } catch { }
    }

    private func clearAll() async {
        do {
            try await history.clear()
            entries = []
        } catch { }
    }
    
    private enum ExportFormat {
        case json, csv, plaintext
    }
    
    private func exportHistory(format: ExportFormat) async {
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
            let allEntries = try await history.recent(limit: 5000)
            var exportData: Data?
            
            switch format {
            case .json:
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                encoder.dateEncodingStrategy = .iso8601
                exportData = try encoder.encode(allEntries)
                
            case .csv:
                var csvString = "ID,Timestamp,Mode,Text\n"
                for entry in allEntries {
                    let id = entry.id.uuidString
                    let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
                    let mode = entry.captureMode
                    let text = "\"" + entry.textContent.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    csvString += "\(id),\(timestamp),\(mode),\(text)\n"
                }
                exportData = csvString.data(using: .utf8)
                
            case .plaintext:
                var textString = ""
                for entry in allEntries {
                    let timestamp = entry.timestamp.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                    textString += "[\(timestamp)] (\(entry.captureMode))\n"
                    textString += "\(entry.textContent)\n"
                    textString += "----------------------------------------\n\n"
                }
                exportData = textString.data(using: .utf8)
            }
            
            if let data = exportData {
                try data.write(to: url)
            }
        } catch {
            print("Failed to export history: \(error)")
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
        Text(entry.textContent.isEmpty ? "No text detected" : entry.textContent)
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
        guard let data = try? await history.thumbnailData(for: entry.id),
              let image = NSImage(data: data)
        else { return }
        thumbnailImage = image
    }
}
