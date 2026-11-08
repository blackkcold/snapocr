import AppKit
import SwiftUI

struct ScreenshotShelfCardView: View {
    let card: ScreenshotShelfCard
    let cardHeight: CGFloat
    let imageOpacity: Double
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?

    private var cardWidth: CGFloat {
        let size = card.imagePixelSize
        guard size.width > 0, size.height > 0 else { return cardHeight * 4 / 3 }
        return cardHeight * size.width / size.height
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(.quaternary)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .opacity(imageOpacity)
                    .frame(width: cardWidth, height: cardHeight)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: card.errorMessage == nil ? "photo" : "exclamationmark.triangle")
                        .font(.title3)
                        .accessibilityHidden(true)
                    Text(card.errorMessage ?? "Preparing Screenshot Preview…")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(width: cardWidth, height: cardHeight)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay(alignment: .topTrailing) {
            Menu {
                Button(action: onEdit) {
                    Label("Edit Screenshot", systemImage: "pencil")
                }
                Button(action: onCopy) {
                    Label("Copy Screenshot", systemImage: "doc.on.doc")
                }
                Button(action: onPin) {
                    Label("Pin Screenshot", systemImage: "pin")
                }
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from Shelf", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .padding(5)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help(Text("Screenshot Actions"))
            .accessibilityLabel(Text("Screenshot Actions"))
        }
        .overlay(alignment: .bottomLeading) {
            if let feedbackMessage = card.feedbackMessage {
                Text(feedbackMessage)
                    .font(.caption2)
                    .lineLimit(2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(5)
            }
        }
        .clipShape(.rect(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .task(id: card.thumbnailData) {
            guard let data = card.thumbnailData else {
                thumbnail = nil
                return
            }
            thumbnail = NSImage(data: data)
        }
    }
}
