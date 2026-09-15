import AppKit
import HistoryCore
import SwiftUI

struct HistoryScreenshotCard: View {
  let entry: HistoryEntry
  let imageSize: CGSize?
  let isSelected: Bool
  let isUpdatingFavourite: Bool
  let onSelect: () -> Void
  let onOpen: () -> Void
  let onFavourite: () -> Void
  @State private var thumbnail: NSImage?

  private var aspectRatio: CGFloat {
    guard let size = imageSize, size.width > 0, size.height > 0 else { return 4 / 3 }
    return size.width / size.height
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        ZStack {
          if let thumbnail {
            Image(nsImage: thumbnail).resizable().scaledToFit()
          } else {
            Rectangle().fill(.quaternary)
              .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
          }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .accessibilityLabel(Text(entry.timestamp, format: .dateTime))
        .accessibilityAction(named: Text("Open in Editor"), onOpen)

        Button(action: onFavourite) {
          Image(systemName: entry.isFavourite ? "star.fill" : "star")
            .foregroundStyle(entry.isFavourite ? Color.yellow : Color.primary)
            .frame(width: 28, height: 28)
            .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .disabled(isUpdatingFavourite)
        .help(Text(entry.isFavourite ? LocalizedStringKey("Remove favourite") : LocalizedStringKey("Add favourite")))
        .accessibilityLabel(
            Text(entry.isFavourite ? LocalizedStringKey("Remove favourite") : LocalizedStringKey("Add favourite"))
        )
      }
      Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute())
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .padding(5)
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        .allowsHitTesting(false)
    }
    .task(id: entry.id) {
      guard let history = HistoryActor.shared,
        let data = try? await history.thumbnailData(for: entry.id), !Task.isCancelled
      else { return }
      thumbnail = NSImage(data: data)
    }
  }
}
