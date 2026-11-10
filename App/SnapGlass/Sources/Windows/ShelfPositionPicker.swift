import SharedKit
import SwiftUI

/// A monitor-shaped picker that shows exactly where the floating shelf will appear.
///
/// Six mini shelves sit at the top and bottom edges of the preview. The top-center option is the
/// default because it keeps the shelf below the menu bar and out of the way of the user's work.
struct ShelfPositionPicker: View {
    @Binding var selection: ScreenshotShelfAnchor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))

                VStack(spacing: 0) {
                    menuBarPreview
                    Spacer(minLength: 0)
                }

                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        anchorButton(.topLeading, alignment: .leading)
                        Spacer(minLength: 0)
                        anchorButton(.top, alignment: .center)
                        Spacer(minLength: 0)
                        anchorButton(.topTrailing, alignment: .trailing)
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .bottom, spacing: 0) {
                        anchorButton(.bottomLeading, alignment: .leading)
                        Spacer(minLength: 0)
                        anchorButton(.bottom, alignment: .center)
                        Spacer(minLength: 0)
                        anchorButton(.bottomTrailing, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 26)
            }
            .frame(height: 168)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Screenshot shelf position"))
        }
    }

    private var menuBarPreview: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 3, height: 3)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 38, height: 3)
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 22, height: 3)
        }
        .padding(.horizontal, 10)
        .frame(height: 18)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func anchorButton(
        _ anchor: ScreenshotShelfAnchor,
        alignment: HorizontalAlignment
    ) -> some View {
        Button {
            selection = anchor
        } label: {
            MiniShelfGlyph(isSelected: selection == anchor)
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(anchor.localizationKey)))
        .accessibilityLabel(Text(LocalizedStringKey(anchor.localizationKey)))
        .accessibilityAddTraits(selection == anchor ? .isSelected : [])
    }
}

private struct MiniShelfGlyph: View {
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.28))
                .frame(height: 1)
                .padding(.horizontal, 2)

            HStack(alignment: .top, spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.32))
                        .frame(width: 7, height: 11)
                }
            }
            .padding(.top, 2)
        }
        .frame(width: 36, height: 20, alignment: .top)
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.16),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
