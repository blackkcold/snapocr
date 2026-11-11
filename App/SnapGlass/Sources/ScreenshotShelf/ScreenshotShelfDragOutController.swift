import AppKit
import CaptureCore
import ImageIO

/// The outcome of inspecting one pointer event while a shelf card is being dragged.
enum ScreenshotShelfDragOutDecision: Equatable {
    /// Keep the event flowing to the SwiftUI reorder gesture.
    case passThrough
    /// The pointer left the shelf but the plaintext file is not ready yet.
    case prepareFile
    /// Everything is ready: hand the drag to a native dragging session.
    case beginSession

    static func decide(
        previewExists: Bool,
        isOutside: Bool,
        artifactExists: Bool
    ) -> ScreenshotShelfDragOutDecision {
        guard previewExists, isOutside else { return .passThrough }
        return artifactExists ? .beginSession : .prepareFile
    }
}

/// Carries the drag to the system and reports when it ends.
@MainActor
final class ScreenshotShelfDraggingSource: NSObject, NSDraggingSource {
    private let onEnd: () -> Void

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
        super.init()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onEnd()
    }
}

/// Turns the shelf's in-panel reorder gesture into a system file drag once the
/// pointer leaves the panel.
///
/// The controller is driven by `ScreenshotShelfPanel.sendEvent(_:)`: a window
/// keeps receiving `leftMouseDragged` after mouse-down even when the pointer
/// leaves its bounds, so the real `NSEvent` used to start the native session is
/// the same event the reorder gesture would have consumed. The SwiftUI gesture
/// stays untouched while the pointer is inside the shelf.
@MainActor
final class ScreenshotShelfDragOutController {
    private weak var panel: ScreenshotShelfPanel?
    private let model: ScreenshotShelfViewModel
    private let exportStore: ScreenshotShelfDragExportStore
    private let dataProvider: (UUID) async throws -> Data?
    private let now: () -> Date

    private var handoffActive = false
    private var preparingCaptureID: UUID?
    private var preparationStartedAt: Date?
    private var sessionSource: ScreenshotShelfDraggingSource?
    private var lastPointerLocal: CGPoint?

    /// True while a native file-drag session started from the shelf is in flight.
    var isNativeDragSessionActive: Bool { handoffActive }

    /// How long a card may wait for its plaintext copy before the next pointer
    /// event retries the preparation.
    private let preparationTimeout: TimeInterval = 1.5

    init(
        model: ScreenshotShelfViewModel,
        exportStore: ScreenshotShelfDragExportStore,
        dataProvider: @escaping (UUID) async throws -> Data?,
        now: @escaping () -> Date = Date.init
    ) {
        self.model = model
        self.exportStore = exportStore
        self.dataProvider = dataProvider
        self.now = now
    }

    func attach(panel: ScreenshotShelfPanel) {
        self.panel = panel
    }

    // MARK: - Event handling

    /// Handles one window event. Returns `true` when the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel else { return false }

        switch event.type {
        case .leftMouseDragged:
            return handleDrag(event, panel: panel)
        case .leftMouseUp:
            guard handoffActive else { return false }
            handoffActive = false
            return true
        default:
            return false
        }
    }

    private func handleDrag(_ event: NSEvent, panel: ScreenshotShelfPanel) -> Bool {
        let preview = model.dragPreview
        let pointer = panel.convertPoint(toScreen: event.locationInWindow)
        let localPointer = panel.contentView.map {
            localPoint(fromWindow: event.locationInWindow, in: $0)
        } ?? .zero
        let isOutside = ScreenshotShelfDragOutGeometry.isOutside(
            point: pointer,
            panelFrame: panel.frame
        )

        // Only hit the file system once the pointer is actually leaving the shelf;
        // this runs on every mouse-move event.
        var artifact: ScreenshotShelfDragExportStore.Artifact?
        if let preview, isOutside {
            artifact = exportStore.artifact(for: preview.cardID)
        }

        let decision = ScreenshotShelfDragOutDecision.decide(
            previewExists: preview != nil,
            isOutside: isOutside,
            artifactExists: artifact != nil
        )

        switch decision {
        case .passThrough:
            if preview == nil {
                preparingCaptureID = nil
                preparationStartedAt = nil
                lastPointerLocal = nil
            } else {
                lastPointerLocal = localPointer
            }
            return false
        case .prepareFile:
            guard let preview else { return false }
            lastPointerLocal = localPointer
            prepareIfNeeded(preview.cardID)
            return false
        case .beginSession:
            guard let preview, let artifact else { return false }
            beginSession(
                preview: preview,
                artifact: artifact,
                event: event,
                panel: panel,
                pointerLocal: localPointer
            )
            return true
        }
    }

    // MARK: - Preparation

    private func prepareIfNeeded(_ captureID: UUID) {
        if preparingCaptureID == captureID,
            let startedAt = preparationStartedAt,
            now().timeIntervalSince(startedAt) < preparationTimeout {
            return
        }

        preparingCaptureID = captureID
        preparationStartedAt = now()

        Task { [weak self] in
            guard let self else { return }
            guard let data = try? await self.dataProvider(captureID) else { return }
            _ = await self.exportStore.prepare(
                captureID: captureID,
                data: data,
                sourceTypeIdentifier: Self.typeIdentifier(for: data)
            )
        }
    }

    // MARK: - Session

    private func beginSession(
        preview: ScreenshotShelfDragPreview,
        artifact: ScreenshotShelfDragExportStore.Artifact,
        event: NSEvent,
        panel: ScreenshotShelfPanel,
        pointerLocal: CGPoint
    ) {
        guard let view = panel.contentView else { return }

        handoffActive = true
        preparingCaptureID = nil
        preparationStartedAt = nil

        let cardSize = CGSize(width: preview.width, height: model.layout.cardHeight)
        let thumbnail = model.layout.cards
            .first(where: { $0.captureID == preview.cardID })?
            .decodedThumbnail
        let dragImage = ScreenshotShelfDragImageRenderer.image(
            thumbnail: thumbnail,
            cardSize: cardSize
        )

        let item = NSDraggingItem(pasteboardWriter: artifact.url as NSURL)
        item.setDraggingFrame(
            draggingFrame(preview: preview, pointerLocal: pointerLocal, in: view),
            contents: dragImage
        )

        let source = ScreenshotShelfDraggingSource { [weak self] in
            self?.finishSession()
        }
        sessionSource = source

        // Hide the SwiftUI drag preview first so the native drag image appears in
        // the same place instead of both being visible for a frame.
        model.endDrag()
        model.perform(.beginInteraction)
        NSCursor.arrow.set()
        _ = view.beginDraggingSession(with: [item], event: event, source: source)
    }

    private func finishSession() {
        handoffActive = false
        sessionSource = nil
        lastPointerLocal = nil
        model.perform(.endInteraction)
        NSCursor.arrow.set()
    }

    private func draggingFrame(
        preview: ScreenshotShelfDragPreview,
        pointerLocal: CGPoint,
        in view: NSView
    ) -> CGRect {
        let padding = ScreenshotShelfDragImageRenderer.padding
        let cardOrigin = CGPoint(
            x: preview.startX + preview.translation.width,
            y: model.layout.cardTopOffset + preview.translation.height
        )
        // `lastPointerLocal` and this card origin come from the same previous
        // event, so their difference is the exact grab point inside the card.
        let grabOffset: CGPoint
        if let lastPointerLocal {
            grabOffset = CGPoint(
                x: lastPointerLocal.x - cardOrigin.x,
                y: lastPointerLocal.y - cardOrigin.y
            )
        } else {
            grabOffset = CGPoint(x: preview.width / 2, y: model.layout.cardHeight / 2)
        }

        let origin = CGPoint(
            x: pointerLocal.x - grabOffset.x,
            y: pointerLocal.y - grabOffset.y
        )
        let imageRect = CGRect(
            x: origin.x - padding,
            y: origin.y - padding,
            width: preview.width + padding * 2,
            height: model.layout.cardHeight + padding * 2
        )
        return viewRect(fromTopLeft: imageRect, in: view)
    }

    private func localPoint(fromWindow point: NSPoint, in view: NSView) -> CGPoint {
        let converted = view.convert(point, from: nil)
        guard !view.isFlipped else { return converted }
        return CGPoint(x: converted.x, y: view.bounds.height - converted.y)
    }

    /// Converts a SwiftUI top-left-origin rect into the hosting view's coordinates.
    private func viewRect(fromTopLeft rect: CGRect, in view: NSView) -> CGRect {
        guard !view.isFlipped else { return rect }
        return CGRect(
            x: rect.minX,
            y: view.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func typeIdentifier(for data: Data) -> String? {
        ScreenshotShelfImageTypeIdentifier.identifier(for: data)
    }
}
