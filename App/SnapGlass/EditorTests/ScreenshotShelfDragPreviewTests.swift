import AppKit
import Testing

@MainActor
struct ScreenshotShelfDragPreviewTests {
    @Test func beginUpdateAndEndPublishEachDragState() throws {
        let model = ScreenshotShelfViewModel()
        let cardID = UUID()
        var received: [ScreenshotShelfDragPreview?] = []
        model.onDragPreviewChanged = { received.append($0) }

        model.beginDrag(cardID: cardID, startIndex: 2, startX: 44, width: 120)
        var preview = try #require(model.dragPreview)
        #expect(preview.cardID == cardID)
        #expect(preview.startIndex == 2)
        #expect(preview.startX == 44)
        #expect(preview.width == 120)
        #expect(preview.translation == .zero)
        #expect(preview.rotation == 0)
        #expect(model.ghostCardID == cardID)

        preview.translation = CGSize(width: 30, height: -12)
        preview.rotation = 2.5
        model.updateDrag(preview)
        #expect(model.dragPreview?.translation == CGSize(width: 30, height: -12))
        #expect(model.dragPreview?.rotation == 2.5)

        model.endDrag()
        #expect(model.dragPreview == nil)
        #expect(model.ghostCardID == nil)
        #expect(received.count == 3)
        #expect(received[0]?.cardID == cardID)
        #expect(received[1]?.rotation == 2.5)
        #expect(received[2] == nil)
    }

    @Test func beginAndEndHoldAndReleaseTheShelfInteractionOnce() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate

        model.beginDrag(cardID: UUID(), startIndex: 0, startX: 0, width: 80)
        model.endDrag()

        #expect(delegate.actions.count == 2)
        guard delegate.actions.count == 2 else { return }
        guard case .beginInteraction = delegate.actions[0] else {
            Issue.record("Expected beginInteraction")
            return
        }
        guard case .endInteraction = delegate.actions[1] else {
            Issue.record("Expected endInteraction")
            return
        }
    }

    @Test func updateAndEndWithoutAnActiveDragAreIgnored() {
        let model = ScreenshotShelfViewModel()
        var received: [ScreenshotShelfDragPreview?] = []
        model.onDragPreviewChanged = { received.append($0) }

        model.updateDrag(ScreenshotShelfDragPreview(
            cardID: UUID(),
            startIndex: 0,
            startX: 0,
            width: 80,
            translation: .zero,
            rotation: 0
        ))
        model.endDrag()

        #expect(model.dragPreview == nil)
        #expect(model.ghostCardID == nil)
        #expect(received.isEmpty)
    }

    @Test func handOffKeepsTheSourceGhostAndInteractionUntilNativeEnd() throws {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate
        let cardID = UUID()

        model.beginDrag(cardID: cardID, startIndex: 0, startX: 16, width: 80)
        #expect(delegate.actions.count == 1)

        #expect(model.handOffDragToNative(cardID: cardID))

        #expect(model.dragPreview == nil)
        #expect(model.nativeDragCardID == cardID)
        #expect(model.ghostCardID == cardID)
        #expect(delegate.actions.count == 1)

        model.endNativeDrag()

        #expect(model.nativeDragCardID == nil)
        #expect(model.ghostCardID == nil)
        #expect(delegate.actions.count == 2)
        guard delegate.actions.count == 2 else { return }
        guard case .endInteraction = delegate.actions[1] else {
            Issue.record("Expected one endInteraction")
            return
        }

        model.endNativeDrag()
        #expect(delegate.actions.count == 2)
    }

    @Test func aLocalDragCannotBeginDuringNativeHandOff() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate
        let cardID = UUID()
        let otherID = UUID()

        model.beginDrag(cardID: cardID, startIndex: 0, startX: 16, width: 80)
        #expect(model.handOffDragToNative(cardID: cardID))
        model.beginDrag(cardID: otherID, startIndex: 1, startX: 108, width: 80)

        #expect(model.dragPreview == nil)
        #expect(model.nativeDragCardID == cardID)
        #expect(model.ghostCardID == cardID)
        #expect(delegate.actions.count == 1)
    }

    @Test func handOffRejectsAMismatchedOrRepeatedCard() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate
        let cardID = UUID()

        model.beginDrag(cardID: cardID, startIndex: 0, startX: 16, width: 80)
        #expect(!model.handOffDragToNative(cardID: UUID()))
        #expect(model.dragPreview?.cardID == cardID)
        #expect(model.nativeDragCardID == nil)
        #expect(delegate.actions.count == 1)

        #expect(model.handOffDragToNative(cardID: cardID))
        #expect(!model.handOffDragToNative(cardID: cardID))
        #expect(model.nativeDragCardID == cardID)
        #expect(delegate.actions.count == 1)
    }

    @Test func beginDragRejectsAnExistingLocalPreview() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate
        let first = UUID()
        let second = UUID()

        model.beginDrag(cardID: first, startIndex: 0, startX: 16, width: 80)
        model.beginDrag(cardID: second, startIndex: 1, startX: 108, width: 80)

        #expect(model.dragPreview?.cardID == first)
        #expect(delegate.actions.count == 1)
    }

    @Test func localCancelLatchesUntilTheGestureEndsOrANewPointerDown() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate
        let first = UUID()
        let second = UUID()

        model.beginDrag(cardID: first, startIndex: 0, startX: 16, width: 80)
        model.cancelLocalDrag()
        #expect(model.dragPreview == nil)
        #expect(model.isLocalDragCancelled)
        #expect(delegate.actions.count == 2)

        model.beginDrag(cardID: second, startIndex: 1, startX: 108, width: 80)
        #expect(model.dragPreview == nil)
        #expect(delegate.actions.count == 2)

        model.resetLocalDragCancellation()
        model.beginDrag(cardID: second, startIndex: 1, startX: 108, width: 80)
        #expect(model.dragPreview?.cardID == second)
        #expect(delegate.actions.count == 3)

        model.endDrag()
        #expect(!model.isLocalDragCancelled)
        #expect(delegate.actions.count == 4)
    }

    @Test func cancelWithoutAPreviewStillLatchesWithoutReleasingInteraction() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate

        model.cancelLocalDrag()
        #expect(model.isLocalDragCancelled)
        #expect(delegate.actions.isEmpty)

        model.beginDrag(cardID: UUID(), startIndex: 0, startX: 16, width: 80)
        #expect(model.dragPreview == nil)
        #expect(delegate.actions.isEmpty)

        model.endDrag()
        #expect(!model.isLocalDragCancelled)

        model.beginDrag(cardID: UUID(), startIndex: 0, startX: 16, width: 80)
        #expect(model.dragPreview != nil)
        #expect(delegate.actions.count == 1)
    }

    @Test func cancelThenGestureEndResetsLatchAndAllowsTheNextDrag() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate
        let first = UUID()
        let second = UUID()

        model.beginDrag(cardID: first, startIndex: 0, startX: 16, width: 80)
        model.cancelLocalDrag()
        model.beginDrag(cardID: second, startIndex: 1, startX: 108, width: 80)
        #expect(model.dragPreview == nil)
        #expect(delegate.actions.count == 2)

        model.endDrag()
        #expect(!model.isLocalDragCancelled)
        #expect(delegate.actions.count == 2)

        model.beginDrag(cardID: second, startIndex: 1, startX: 108, width: 80)
        #expect(model.dragPreview?.cardID == second)
        #expect(delegate.actions.count == 3)
    }

    @Test func nativeDragUsesCurrentCardSizeAndRejectsInvalidGeometry() {
        var layout = ScreenshotShelfLayout.empty
        layout.cards = [
            ScreenshotShelfCard(
                captureID: UUID(),
                imagePixelSize: CGSize(width: 80, height: 60),
                displayScale: 1,
                scaleSourcePixelWidth: nil
            ),
            ScreenshotShelfCard(
                captureID: UUID(),
                imagePixelSize: CGSize(width: 120, height: 60),
                displayScale: 1,
                scaleSourcePixelWidth: nil
            ),
        ]
        layout.cardWidths = [80, 120]
        layout.cardHeight = 90

        #expect(
            ScreenshotShelfNativeDragGeometry.cardSize(at: 1, layout: layout)
                == CGSize(width: 120, height: 90)
        )

        layout.cardWidths = [80, 0]
        #expect(ScreenshotShelfNativeDragGeometry.cardSize(at: 1, layout: layout) == nil)
        #expect(ScreenshotShelfNativeDragGeometry.cardSize(at: 2, layout: layout) == nil)
    }

    @Test func nativeGhostKeepsTheStableCardIdentityAcrossLayoutChanges() {
        let model = ScreenshotShelfViewModel()
        let cardID = UUID()
        model.layout.cards = [
            ScreenshotShelfCard(
                captureID: cardID,
                imagePixelSize: CGSize(width: 80, height: 60),
                displayScale: 1,
                scaleSourcePixelWidth: nil
            ),
        ]

        model.beginDrag(cardID: cardID, startIndex: 0, startX: 16, width: 80)
        model.handOffDragToNative(cardID: cardID)

        model.layout.cards = [
            ScreenshotShelfCard(
                captureID: UUID(),
                imagePixelSize: CGSize(width: 60, height: 60),
                displayScale: 1,
                scaleSourcePixelWidth: nil
            ),
            ScreenshotShelfCard(
                captureID: cardID,
                imagePixelSize: CGSize(width: 80, height: 60),
                displayScale: 1,
                scaleSourcePixelWidth: nil
            ),
        ]

        #expect(model.nativeDragCardID == cardID)
        #expect(model.ghostCardID == cardID)

        model.endNativeDrag()
        #expect(model.ghostCardID == nil)
    }
}

@MainActor
private final class InteractionRecordingDelegate: ScreenshotShelfViewModelDelegate {
    private(set) var actions: [ScreenshotShelfAction] = []

    func screenshotShelfViewModel(
        _ model: ScreenshotShelfViewModel,
        perform action: ScreenshotShelfAction
    ) {
        actions.append(action)
    }
}
