import SharedKit
import SwiftUI

/// The editor's bottom banner for the second tutorial step.
///
/// A banner rather than a toast: a toast disappears after three seconds, which is
/// shorter than the time it takes to read a sentence and find the shelf. This stays
/// until the user acts on it or dismisses it.
struct EditorTutorialBanner: View {
    /// Called when the user dismisses the banner or opens the shelf.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey("Saved to history and the shelf"))
                    .font(DS.Typography.captionStrong)
                Text(LocalizedStringKey("Close the editor when you are done; your capture is already saved."))
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(LocalizedStringKey("Got it")) {
                onDismiss()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.s14)
        .padding(.vertical, DS.Space.s10)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}
