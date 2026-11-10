import AppKit
import CaptureCore
import HistoryCore
import ImageIO
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

  /// The raw thumbnail plus the presentation style. Style changes must
  /// invalidate the cached image, or removing a treatment would keep showing
  /// the old preview.
  private var thumbnailKey: String {
    let path = entry.thumbnailPath?.path ?? entry.id.uuidString
    return path + "|" + (entry.mockupStyleJSON ?? "")
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

        if entry.mockupStyleJSON != nil {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.45), in: Circle())
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityLabel(Text("Beautified"))
        }

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
    .task(id: thumbnailKey) {
      // 覆盖原记录 / 还原原图会改变 thumbnailPath，但 id 不变；只按 id
      // 触发任务会让格子继续显示旧图，甚至按新宽高比拉伸。
      let key = thumbnailKey
      if let cached = HistoryThumbnailCache.shared.image(for: key) {
        thumbnail = cached
        return
      }
      guard let history = HistoryActor.shared,
        let data = try? await history.thumbnailData(for: entry.id), !Task.isCancelled
      else { return }
      guard let image = Self.displayImage(from: data, styleJSON: entry.mockupStyleJSON) else { return }
      HistoryThumbnailCache.shared.store(image, for: key)
      thumbnail = image
    }
  }

  /// Renders the stored thumbnail through the entry's presentation style.
  ///
  /// The grid thumbnail is only ~200 px, so this keeps the history browser
  /// visually in sync with copy/drag/export without paying for a full-size
  /// composite on every scroll.
  private static func displayImage(from data: Data, styleJSON: String?) -> NSImage? {
    guard
      let styleJSON,
      let styleData = styleJSON.data(using: .utf8),
      let style = try? JSONDecoder().decode(MockupStyle.self, from: styleData),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let raw = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let rendered = MockupRenderer.render(raw, style: style)
    else {
      return NSImage(data: data)
    }
    return NSImage(
      cgImage: rendered,
      size: NSSize(width: rendered.width, height: rendered.height)
    )
  }
}


/// 缩略图内存缓存：卡片滚出屏幕再滚回来不必重新读盘 + 解码。
/// `NSCache` 会在系统内存压力下自动回收。
@MainActor
final class HistoryThumbnailCache {
  static let shared = HistoryThumbnailCache()
  private let cache = NSCache<NSString, NSImage>()

  private init() {
    cache.countLimit = 200
  }

  func image(for key: String) -> NSImage? {
    cache.object(forKey: key as NSString)
  }

  func store(_ image: NSImage, for key: String) {
    cache.setObject(image, forKey: key as NSString)
  }
}
