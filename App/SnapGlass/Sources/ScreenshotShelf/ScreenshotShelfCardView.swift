import AppKit
import CaptureCore
import SwiftUI

/// A single screenshot hanging from the shelf rail by a thread and ring.
struct ScreenshotShelfCardView: View {
    let card: ScreenshotShelfCard
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let imageOpacity: Double
    let isHovered: Bool
    let isDragging: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onRemove: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    var showsHanger: Bool = true
    var railEmphasis: Bool = false

    private var isLifted: Bool { isHovered && !isDragging }

    var body: some View {
        ZStack(alignment: .top) {
            cardContent
                .rotationEffect(.degrees(isLifted ? 0.5 : 0), anchor: .top)

            if showsHanger {
                ThreadHangerView(railEmphasis: railEmphasis)
                    .offset(y: -ScreenshotShelfMetrics.hangerHeight)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        // The ring is the pendulum pivot: the card and its thread swing around the point where
        // the ring hangs on the rail, so the ring cannot drift away from the rail on hover.
        .rotationEffect(
            .degrees(isLifted ? 2 : 0),
            anchor: UnitPoint(x: 0.5, y: -ScreenshotShelfMetrics.ringCenterAboveCard / max(cardHeight, 1))
        )
        .shadow(
            color: .black.opacity(isDragging ? 0.25 : (isLifted ? 0.18 : 0.12)),
            radius: isDragging ? 16 : (isLifted ? 12 : 8),
            x: 0,
            y: isDragging ? 8 : (isLifted ? 5 : 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { onOpen() }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Screenshot"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open Screenshot")) { onOpen() }
        .accessibilityAction(named: Text("Copy Screenshot")) { onCopy() }
        .accessibilityAction(named: Text("Pin Screenshot")) { onPin() }
        .accessibilityAction(named: Text("Move Left")) {
            if canMoveLeft { onMoveLeft() }
        }
        .accessibilityAction(named: Text("Move Right")) {
            if canMoveRight { onMoveRight() }
        }
        .accessibilityAction(named: Text("Remove from Shelf")) { onRemove() }
    }

    private var cardContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)

            thumbnail

            if card.decodedThumbnail == nil && card.thumbnailData == nil {
                placeholder
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if isLifted {
                removeButton
            }
        }
        .overlay(alignment: .topLeading) {
            if card.isMockup {
                Image(systemName: "sparkles")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(5)
                    .accessibilityLabel(Text("Beautified"))
            }
        }
        .overlay(alignment: .bottomLeading) {
            feedback
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = card.decodedThumbnail {
            if card.isMockup {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(imageOpacity)
                    .frame(width: cardWidth, height: cardHeight)
                    .background(.quaternary)
            } else {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .opacity(imageOpacity)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 5) {
            Image(systemName: card.errorMessage == nil ? "photo" : "exclamationmark.triangle")
                .font(.title3)
                .accessibilityHidden(true)

            Group {
                if let errorMessage = card.errorMessage {
                    Text(errorMessage.resolved(using: { AppLocalization.string($0) }))
                } else {
                    Text("Preparing Screenshot Preview…")
                }
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .padding(8)
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 16, height: 16)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .padding(5)
        .accessibilityLabel(Text("Remove from Shelf"))
    }

    @ViewBuilder
    private var feedback: some View {
        if let feedbackMessage = card.feedbackMessage {
            Text(feedbackMessage.resolved(using: { AppLocalization.string($0) }))
                .font(.caption2)
                .lineLimit(2)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
                .padding(5)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(action: onOpen) {
            Label("Edit Screenshot", systemImage: "pencil")
        }
        Button(action: onCopy) {
            Label("Copy Screenshot", systemImage: "doc.on.doc")
        }
        Button(action: onPin) {
            Label("Pin Screenshot", systemImage: "pin")
        }

        Divider()

        Button(action: onMoveLeft) {
            Label("Move Left", systemImage: "arrow.left")
        }
        .disabled(!canMoveLeft)

        Button(action: onMoveRight) {
            Label("Move Right", systemImage: "arrow.right")
        }
        .disabled(!canMoveRight)

        Divider()

        Button(role: .destructive, action: onRemove) {
            Label("Remove from Shelf", systemImage: "trash")
        }
    }
}

/// The ring, the 1 pt thread, and the 2 pt attachment dot form one hanging piece. The card view
/// swings the whole piece around the ring centre, so the ring stays visually seated on the rail.
private struct ThreadHangerView: View {
    let railEmphasis: Bool

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .strokeBorder(
                    Color.primary.opacity(railEmphasis ? 0.7 : 0.5),
                    lineWidth: 1
                )
                .frame(width: ScreenshotShelfMetrics.ringDiameter, height: ScreenshotShelfMetrics.ringDiameter)

            Rectangle()
                .fill(Color.primary.opacity(0.55))
                .frame(width: 1, height: ScreenshotShelfMetrics.threadLength)

            Circle()
                .fill(Color.primary.opacity(0.7))
                .frame(
                    width: ScreenshotShelfMetrics.attachmentDotDiameter,
                    height: ScreenshotShelfMetrics.attachmentDotDiameter
                )
        }
        .frame(width: ScreenshotShelfMetrics.ringDiameter, height: ScreenshotShelfMetrics.hangerHeight, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.15), value: railEmphasis)
    }
}
