import SharedKit
import SwiftUI

/// The shelf's one-line strip for the third tutorial step.
///
/// Drawn by the shelf itself, so the instruction sits on the surface it describes.
/// It disappears after the first successful drag or after a few seconds, because a
/// permanent strip would compete with the cards for vertical room.
struct ScreenshotShelfTutorialStrip: View {
    /// Called when the strip should stop being shown.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s6) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(LocalizedStringKey("Drag a card straight into any app."))
                .font(DS.Typography.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("Close")))
        }
        .padding(.horizontal, DS.Space.s10)
        .padding(.vertical, DS.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }
}
