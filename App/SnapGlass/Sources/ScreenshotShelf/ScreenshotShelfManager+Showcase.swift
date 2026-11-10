#if DEBUG
import AppKit

/// Showcase helpers used by the documentation exporter only.
///
/// Kept in its own file so the shelf manager stays under the project's source
/// length limit; debug builds only.
@MainActor
extension ScreenshotShelfManager {
    func showcaseHoldOpen() {
        viewModel.perform(.beginInteraction)
    }

    func showcaseFocus(index: Int) {
        let cards = viewModel.layout.cards
        guard index >= 0, index < cards.count else { return }
        viewModel.setFocusedCapture(cards[index].captureID)
    }

    func showcaseBeginDrag(index: Int) {
        let layout = viewModel.layout
        guard index >= 0, index < layout.cards.count, index < layout.cardWidths.count else {
            return
        }
        let preceding = layout.cardWidths.prefix(index).reduce(0, +)
        let metrics = layout.metrics
        let startX = metrics.shadowInset + preceding + metrics.cardSpacing * CGFloat(index)
        viewModel.beginDrag(
            cardID: layout.cards[index].captureID,
            startIndex: index,
            startX: startX,
            width: layout.cardWidths[index]
        )
        guard var preview = viewModel.dragPreview else { return }
        preview.translation = CGSize(width: 22, height: 34)
        preview.rotation = -3
        viewModel.updateDrag(preview)
    }
}
#endif
