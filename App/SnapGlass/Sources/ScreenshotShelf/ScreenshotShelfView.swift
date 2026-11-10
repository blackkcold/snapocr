import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// Chromeless shelf content: a thin rail, hanging thumbnails, and a hover-only action menu.
struct ScreenshotShelfView: View {
    @ObservedObject var model: ScreenshotShelfViewModel

    @State private var dropTargetIndex: Int?

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
        .onChange(of: model.dragPreview) { preview in
            if preview == nil {
                dropTargetIndex = nil
            }
        }
    }

    private var expandedView: some View {
        ZStack(alignment: .topLeading) {
            rail
            cardsRow
            if model.dragPreview != nil {
                reorderZoneOverlay
            }
            endMenu
        }
        .animation(.easeOut(duration: 0.15), value: model.dragPreview != nil)
    }

    /// Dashed outline that marks the shelf interior as reorder-only while a card
    /// is being dragged. It fades out the moment the drag becomes a file drag.
    private var reorderZoneOverlay: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
                Color.secondary.opacity(0.55),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .frame(width: reorderZoneWidth, height: layout.cardHeight + 12)
            .offset(x: metrics.shadowInset - 6, y: layout.cardTopOffset - 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    private var reorderZoneWidth: CGFloat {
        guard !layout.cardWidths.isEmpty else { return 0 }
        // Wrap the whole shelf content, including the end menu, so the outline
        // reads as "this surface is reorder-only" rather than cutting through it.
        return layout.visualWidth + 12
    }

    /// The collapsed state is a small rail segment plus a count badge. It stays visible and
    /// expands on approach, so the shelf never disappears just because the pointer left.
    private var collapsedView: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(model.isPointerInside ? 0.55 : 0.35))
                .frame(width: 46, height: 8)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
                .offset(x: -7)

            Text("\(layout.cards.count)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.accentColor))
                .offset(x: 23)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.perform(.expand) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Screenshot Shelf"))
        .accessibilityValue(Text("\(layout.cards.count)"))
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
                        isHovered: hoveredCardID == card.captureID
                    )
                    .frame(width: layout.cardWidths[index], height: layout.cardHeight)
                    .offset(x: siblingOffset(for: index))
                    .opacity(model.dragPreview?.cardID == card.captureID ? 0 : 1)
                    .accessibilityHidden(model.dragPreview?.cardID == card.captureID)
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
            isDragging: model.dragPreview?.cardID == card.captureID,
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
            railEmphasis: model.isPointerInside
        )
    }

    private var endMenu: some View {
        Menu {
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
                if model.dragPreview == nil {
                    NSCursor.closedHand.set()
                    model.beginDrag(
                        cardID: card.captureID,
                        startIndex: index,
                        startX: startX(for: index),
                        width: layout.cardWidths[index]
                    )
                    dropTargetIndex = index
                }
                guard var drag = model.dragPreview else { return }
                drag.translation = value.translation
                let predicted = value.predictedEndTranslation.width - value.translation.width
                drag.rotation = min(max(predicted * 0.015, -4), 4)
                model.updateDrag(drag)

                let centerX = drag.startX + value.translation.width + drag.width / 2
                let target = targetIndex(for: centerX, startIndex: drag.startIndex)
                if target != dropTargetIndex {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dropTargetIndex = target
                    }
                }
            }
            .onEnded { value in
                guard let drag = model.dragPreview else { return }
                let target = dropTargetIndex ?? drag.startIndex
                let inside = CGRect(origin: .zero, size: layout.panelSize).contains(value.location)
                if inside {
                    model.perform(.move(card.captureID, target))
                }
                NSCursor.arrow.set()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    model.endDrag()
                    dropTargetIndex = nil
                }
            }
    }

    private func siblingOffset(for index: Int) -> CGFloat {
        guard let drag = model.dragPreview, let target = dropTargetIndex else { return 0 }
        let shift = drag.width + metrics.cardSpacing
        if target > drag.startIndex {
            if index > drag.startIndex, index <= target {
                return -shift
            }
        } else if target < drag.startIndex {
            if index >= target, index < drag.startIndex {
                return shift
            }
        }
        return 0
    }

    private func startX(for index: Int) -> CGFloat {
        guard index > 0 else { return metrics.shadowInset }
        let precedingWidth = layout.cardWidths.prefix(index).reduce(0, +)
        return metrics.shadowInset
            + precedingWidth
            + metrics.cardSpacing * CGFloat(index)
    }

    private func midpoint(for index: Int) -> CGFloat {
        guard index >= 0, index < layout.cardWidths.count else { return 0 }
        return startX(for: index) + layout.cardWidths[index] / 2
    }

    private func targetIndex(for centerX: CGFloat, startIndex: Int) -> Int {
        guard !layout.cardWidths.isEmpty else { return 0 }
        var target = min(max(startIndex, 0), layout.cardWidths.count - 1)
        let originMidpoint = midpoint(for: target)
        if centerX > originMidpoint {
            while target + 1 < layout.cardWidths.count,
                  centerX > midpoint(for: target + 1) {
                target += 1
            }
        } else if centerX < originMidpoint {
            while target > 0, centerX < midpoint(for: target - 1) {
                target -= 1
            }
        }
        return target
    }
}
