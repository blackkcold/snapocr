import SwiftUI

struct ScreenshotShelfView: View {
    let cards: [ScreenshotShelfCard]
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    let cardHeight: CGFloat
    let imageOpacity: Double
    let onEdit: (UUID) -> Void
    let onCopy: (UUID) -> Void
    let onPin: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let onClear: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Recent Screenshots")
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(action: onClear) {
                    Label("Clear Shelf", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(cards.isEmpty)

                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(Text("Hide Screenshot Shelf"))
                .accessibilityLabel(Text("Hide Screenshot Shelf"))
            }
            .frame(height: 26)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(cards) { card in
                        ScreenshotShelfCardView(
                            card: card,
                            cardHeight: cardHeight,
                            imageOpacity: imageOpacity,
                            onEdit: { onEdit(card.captureID) },
                            onCopy: { onCopy(card.captureID) },
                            onPin: { onPin(card.captureID) },
                            onRemove: { onRemove(card.captureID) }
                        )
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.hidden)
            .frame(height: cardHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: panelWidth, height: panelHeight)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 14))
    }
}
