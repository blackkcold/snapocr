import AppKit
import HistoryCore
import SwiftUI

// MARK: - Color History Card

struct ColorHistoryCard: View {
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

struct HistoryRow: View {
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
                .scaledToFill()
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
