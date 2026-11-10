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

        preview.translation = CGSize(width: 30, height: -12)
        preview.rotation = 2.5
        model.updateDrag(preview)
        #expect(model.dragPreview?.translation == CGSize(width: 30, height: -12))
        #expect(model.dragPreview?.rotation == 2.5)

        model.endDrag()
        #expect(model.dragPreview == nil)
        #expect(received.count == 3)
        #expect(received[0]?.cardID == cardID)
        #expect(received[1]?.rotation == 2.5)
        #expect(received[2] == nil)
    }

    @Test func beginAndEndHoldAndReleaseTheShelfInteraction() {
        let model = ScreenshotShelfViewModel()
        let delegate = InteractionRecordingDelegate()
        model.delegate = delegate

        model.beginDrag(cardID: UUID(), startIndex: 0, startX: 0, width: 80)
        model.endDrag()

        guard delegate.actions.count == 2 else {
            Issue.record("Expected one begin and one end interaction, got \(delegate.actions.count)")
            return
        }
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
        #expect(received.isEmpty)
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
