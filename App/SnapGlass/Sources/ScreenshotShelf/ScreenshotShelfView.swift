import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// Chromeless shelf content: a thin rail, hanging thumbnails, and a hover-only action menu.
struct ScreenshotShelfView: View {
    @ObservedObject var model: ScreenshotShelfViewModel

    private static let coordinateSpaceName = "screenshot-shelf"

    private var layout: ScreenshotShelfLayout { model.layout }
    private var metrics: ScreenshotShelfMetrics { layout.metrics }

    var body: some View {
        Group {
            if layout.mode == .collapsed {
                collapsedView
            } else {
                expandedView
            }
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .topLeading)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .contentShape(Rectangle())
        .environment(\.locale, layout.locale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recent Screenshots"))
    }

    private var expandedView: some View {
        ZStack(alignment: .topLeading) {
            rail
            cardsRow
            sourceGhost
            endMenu
        }
    }

    private var ghostCardID: UUID? {
        model.ghostCardID
    }

    @ViewBuilder
    private var sourceGhost: some View {
        if let ghostCardID,
           let index = layout.cards.firstIndex(where: { $0.captureID == ghostCardID }),
           index < layout.cardWidths.count {
            ScreenshotShelfSourceGhostView(
                card: layout.cards[index],
                cardWidth: layout.cardWidths[index],
                cardHeight: layout.cardHeight
            )
            .frame(width: layout.cardWidths[index], height: layout.cardHeight)
            .offset(x: startX(for: index), y: layout.cardTopOffset)
            .zIndex(100)
        }
    }

    /// The collapsed state is a compact handle that stays visible and expands once the pointer
    /// rests on it. It is deliberately small: the always-on-top panel routes pointer events for
    /// its whole frame, so every unused margin would steal clicks from the app underneath.
    ///
    /// The content below is 50×12 and must stay inside the 56×14 handle window.
    private var collapsedView: some View {
        HStack(spacing: 4) {
            collapsedRail
            collapsedCountBadge
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.perform(.expand) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Screenshot Shelf"))
        .accessibilityValue(Text("\(layout.cards.count)"))
        .accessibilityAction { model.perform(.expand) }
        .animation(.easeOut(duration: 0.14), value: model.isPointerInside)
    }

    /// A miniature of the expanded rail so the collapsed shelf still reads as the same object.
    private var collapsedRail: some View {
        let opacity = model.isPointerInside ? 0.46 : 0.26
        let thickness: CGFloat = model.isPointerInside ? 2.5 : 2
        return ZStack {
            Capsule()
                .fill(Color.primary.opacity(opacity))
                .frame(width: 32, height: thickness)
            HStack(spacing: 0) {
                Capsule()
                    .fill(Color.primary.opacity(opacity))
                    .frame(width: 1.5, height: 5)
                Spacer(minLength: 0)
                Capsule()
                    .fill(Color.primary.opacity(opacity))
                    .frame(width: 1.5, height: 5)
            }
            .frame(width: 33)
        }
        .frame(width: 34, height: 8)
    }

    private var collapsedCountBadge: some View {
        Text("\(layout.cards.count)")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(Circle().fill(Color.accentColor))
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(model.isPointerInside ? 0.35 : 0), lineWidth: 0.5)
            }
            .scaleEffect(model.isPointerInside ? 1.06 : 1)
    }

    private var railColor: Color {
        Color.primary.opacity(model.isPointerInside ? 0.35 : 0.18)
    }

    private var rail: some View {
        let railY = metrics.topInset + 2
        let lineWidth = max(0, metrics.visualWidth(cardWidths: layout.cardWidths) - metrics.endMenuWidth)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(railColor)
                .frame(width: lineWidth, height: 1)
                .offset(x: metrics.shadowInset, y: railY)

            Rectangle()
                .fill(railColor)
                .frame(width: 1, height: 5)
                .offset(x: metrics.shadowInset, y: railY - 2)

            Rectangle()
                .fill(railColor)
                .frame(width: 1, height: 5)
                .offset(x: metrics.shadowInset + max(0, lineWidth - 1), y: railY - 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: model.isPointerInside)
    }

    private var cardsRow: some View {
        HStack(alignment: .top, spacing: metrics.cardSpacing) {
            ForEach(layout.cards) { card in
                if let index = layout.cards.firstIndex(where: { $0.id == card.id }),
                   index < layout.cardWidths.count {
                    cardView(
                        card,
                        index: index,
                        isHovered: ghostCardID == nil && hoveredCardID == card.captureID
                    )
                    .frame(width: layout.cardWidths[index], height: layout.cardHeight)
                    .opacity(ghostCardID == card.captureID ? 0 : 1)
                    .accessibilityHidden(ghostCardID == card.captureID)
                    .zIndex(Double(index))
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        )
                    )
                    .gesture(dragGesture(for: card, index: index))
                }
            }
        }
        .padding(.leading, metrics.shadowInset)
        .padding(.top, metrics.cardTopOffset)
    }

    private var hoveredCardID: UUID? {
        guard layout.mode == .expanded, let point = model.pointerLocation else { return nil }
        for (index, card) in layout.cards.enumerated() where index < layout.cardWidths.count {
            let rect = CGRect(
                x: startX(for: index),
                y: layout.cardTopOffset,
                width: layout.cardWidths[index],
                height: layout.cardHeight
            )
            if rect.contains(point) {
                return card.captureID
            }
        }
        return nil
    }

    private func cardView(_ card: ScreenshotShelfCard, index: Int, isHovered: Bool) -> some View {
        ScreenshotShelfCardView(
            card: card,
            cardWidth: layout.cardWidths[index],
            cardHeight: layout.cardHeight,
            imageOpacity: layout.imageOpacity,
            isHovered: isHovered,
            isDragging: ghostCardID == card.captureID,
            canMoveLeft: index > 0,
            canMoveRight: index < layout.cards.count - 1,
            onOpen: { model.perform(.edit(card.captureID)) },
            onCopy: { model.perform(.copy(card.captureID)) },
            onPin: { model.perform(.pin(card.captureID)) },
            onRemove: { model.perform(.remove(card.captureID)) },
            onMoveLeft: { model.perform(.move(card.captureID, max(0, index - 1))) },
            onMoveRight: {
                model.perform(.move(card.captureID, min(layout.cards.count - 1, index + 1)))
            },
            railEmphasis: model.isPointerInside,
            isInteractive: ghostCardID != card.captureID
        )
        .overlay {
            if model.focusedCaptureID == card.captureID {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }

    private var endMenu: some View {
        Menu {
            Button {
                model.perform(.beginKeyboardMode)
            } label: {
                Label("Keyboard Mode", systemImage: "keyboard")
            }
            .disabled(layout.cards.isEmpty)

            Button {
                model.perform(.clear)
            } label: {
                Label("Clear Shelf", systemImage: "trash")
            }
            .disabled(layout.cards.isEmpty)

            Button {
                model.perform(.hide)
            } label: {
                Label("Hide Screenshot Shelf", systemImage: "xmark")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .opacity(model.isPointerInside ? 1 : 0.35)
        .padding(.trailing, metrics.shadowInset)
        .padding(.top, metrics.topInset + 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(200)
        .help(Text("Screenshot Shelf Actions"))
        .accessibilityLabel(Text("Screenshot Shelf Actions"))
    }

    private func dragGesture(for card: ScreenshotShelfCard, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                // A native hand-off clears dragPreview but keeps the interaction
                // locked; a cancelled local drag must also stay cancelled until
                // the gesture ends or a fresh mouse-down resets the latch.
                guard model.nativeDragCardID == nil, !model.isLocalDragCancelled else { return }
                if model.dragPreview == nil {
                    NSCursor.closedHand.set()
                    model.beginDrag(
                        cardID: card.captureID,
                        startIndex: index,
                        startX: startX(for: index),
                        width: layout.cardWidths[index]
                    )
                }
                guard var drag = model.dragPreview else { return }
                drag.translation = value.translation
                let predicted = value.predictedEndTranslation.width - value.translation.width
                drag.rotation = min(max(predicted * 0.015, -4), 4)
                model.updateDrag(drag)
            }
            .onEnded { _ in
                // The native source callback owns cleanup once a system drag
                // session started. A local release always keeps the order.
                guard model.nativeDragCardID == nil else { return }
                NSCursor.arrow.set()
                model.endDrag()
            }
    }

    private func startX(for index: Int) -> CGFloat {
        guard index > 0 else { return metrics.shadowInset }
        let precedingWidth = layout.cardWidths.prefix(index).reduce(0, +)
        return metrics.shadowInset
            + precedingWidth
            + metrics.cardSpacing * CGFloat(index)
    }
}

/// Low-opacity source-slot placeholder shown for the whole drag session.
///
/// It deliberately has no gesture, menu, or hit testing: the dragged card is the
/// system/local drag image, and this view only marks where it came from.
private struct ScreenshotShelfSourceGhostView: View {
    let card: ScreenshotShelfCard
    let cardWidth: CGFloat
    let cardHeight: CGFloat

    private let cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary)

            if let image = card.decodedThumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .opacity(0.30)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
