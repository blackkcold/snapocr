import SharedKit
import SwiftUI

/// A monitor-shaped picker that shows exactly where the floating shelf will appear.
///
/// Three mini shelves sit along the top edge of the preview, just below the menu bar. The shelf
/// is deliberately top-only: a bottom shelf sits behind the Dock and over window content, which
/// made the extra options hard to predict and rarely useful.
struct ShelfPositionPicker: View {
    @Binding var selection: ScreenshotShelfAnchor

    @State private var hoveredAnchor: ScreenshotShelfAnchor?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            // A faint top glow so the glyphs read as a shelf floating on a display.
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.05), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(spacing: 0) {
                menuBarPreview
                Spacer(minLength: 0)
            }

            HStack(alignment: .top, spacing: 0) {
                anchorButton(.topLeading)
                Spacer(minLength: 0)
                anchorButton(.top)
                Spacer(minLength: 0)
                anchorButton(.topTrailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: 88)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Screenshot shelf position"))
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

    private func anchorButton(_ anchor: ScreenshotShelfAnchor) -> some View {
        Button {
            selection = anchor
        } label: {
            MiniShelfGlyph(
                isSelected: selection == anchor,
                isHovered: hoveredAnchor == anchor
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredAnchor = anchor
            } else if hoveredAnchor == anchor {
                hoveredAnchor = nil
            }
        }
        .help(Text(LocalizedStringKey(anchor.localizationKey)))
        .accessibilityLabel(Text(LocalizedStringKey(anchor.localizationKey)))
        .accessibilityAddTraits(selection == anchor ? .isSelected : [])
    }
}

private struct MiniShelfGlyph: View {
    let isSelected: Bool
    var isHovered = false

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
                .fill(fillColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: isSelected ? 1.5 : 0.5)
        }
        .shadow(
            color: isSelected ? Color.accentColor.opacity(0.18) : .clear,
            radius: 4,
            y: 1
        )
        .scaleEffect(isHovered && !isSelected ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fillColor: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.05) }
        return .clear
    }

    private var strokeColor: Color {
        isSelected ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.34 : 0.16)
    }
}
