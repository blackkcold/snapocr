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
