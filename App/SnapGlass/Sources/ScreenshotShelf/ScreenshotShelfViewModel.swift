import AppKit
import CaptureCore
import SharedKit
import SwiftUI

enum ScreenshotShelfMessage: Equatable {
    case localizedKey(String)
    case verbatim(String)

    func resolved(using localize: (String) -> String) -> String {
        switch self {
        case .localizedKey(let key): localize(key)
        case .verbatim(let value): value
        }
    }
}

/// The panel's show/hide phase. `mode` (expanded/collapsed) is tracked separately so a collapse
/// never masquerades as a hide.
enum ScreenshotShelfPhase {
    case hidden
    case appearing
    case visible
    case disappearing
}

/// A capture retained by the current screenshot-shelf session.
struct ScreenshotShelfCard: Identifiable, Equatable {
    let captureID: UUID
    var historyID: UUID?
    var imagePixelSize: CGSize
    let displayScale: CGFloat
    let scaleSourcePixelWidth: CGFloat?
    var thumbnailData: Data?
    var decodedThumbnail: CGImage?
    var errorMessage: ScreenshotShelfMessage?
    var feedbackMessage: ScreenshotShelfMessage?

    var id: UUID { captureID }

    static func == (lhs: ScreenshotShelfCard, rhs: ScreenshotShelfCard) -> Bool {
        lhs.captureID == rhs.captureID
            && lhs.historyID == rhs.historyID
            && lhs.imagePixelSize == rhs.imagePixelSize
            && lhs.displayScale == rhs.displayScale
            && lhs.scaleSourcePixelWidth == rhs.scaleSourcePixelWidth
            && lhs.thumbnailData == rhs.thumbnailData
            && lhs.errorMessage == rhs.errorMessage
            && lhs.feedbackMessage == rhs.feedbackMessage
    }
}

/// Immutable snapshot rendered by the shelf. One assignment updates cards and geometry atomically.
struct ScreenshotShelfLayout {
    var cards: [ScreenshotShelfCard]
    var cardWidths: [CGFloat]
    var panelFrame: CGRect
    var cardHeight: CGFloat
    var imageOpacity: Double
    var locale: Locale
    var metrics: ScreenshotShelfMetrics
    var anchor: ScreenshotShelfAnchor
    var mode: ScreenshotShelfMode = .expanded

    static let empty = ScreenshotShelfLayout(
        cards: [],
        cardWidths: [],
        panelFrame: .zero,
        cardHeight: PreferenceDefaults.screenshotShelfCardHeight,
        imageOpacity: PreferenceDefaults.screenshotShelfImageOpacity,
        locale: .current,
        metrics: ScreenshotShelfMetrics(),
        anchor: .top
    )

    var panelSize: CGSize { panelFrame.size }
    var cardTopOffset: CGFloat { metrics.cardTopOffset }
    var visualWidth: CGFloat { metrics.visualWidth(cardWidths: cardWidths) }
    var isCollapsed: Bool { mode == .collapsed }
}

/// The live drag state shared by the shelf content and the standalone drag-preview window.
///
/// The preview must live outside the shelf panel so it is not clipped by the panel's content-sized
/// window, but the SwiftUI gesture still belongs to the shelf. Keeping the state in the view model
/// gives the manager one observable source for both the source-card gap and the preview panel.
struct ScreenshotShelfDragPreview: Equatable {
    let cardID: UUID
    let startIndex: Int
    let startX: CGFloat
    let width: CGFloat
    var translation: CGSize
    var rotation: Double
}

/// Actions sent from the shelf view back to the manager.
enum ScreenshotShelfAction {
    case edit(UUID)
    case copy(UUID)
    case pin(UUID)
    case remove(UUID)
    case clear
    case hide
    case expand
    case beginInteraction
    case endInteraction
    case move(UUID, Int)
    case beginKeyboardMode
}

@MainActor
protocol ScreenshotShelfViewModelDelegate: AnyObject {
    func screenshotShelfViewModel(_ model: ScreenshotShelfViewModel, perform action: ScreenshotShelfAction)
}

/// Stable observable model for the shelf panel.
///
/// The panel keeps one hosting view for the lifetime of the app. Updates replace `layout` instead of
/// rebuilding the root view, which keeps the SwiftUI identity graph stable during capture bursts.
@MainActor
final class ScreenshotShelfViewModel: ObservableObject {
    @Published var layout: ScreenshotShelfLayout
    @Published private(set) var isPointerInside = false
    @Published private(set) var pointerLocation: CGPoint?
    @Published private(set) var dragPreview: ScreenshotShelfDragPreview?
    @Published private(set) var focusedCaptureID: UUID?

    weak var delegate: ScreenshotShelfViewModelDelegate?
    var onPointerInsideChanged: ((Bool) -> Void)?
    var onDragPreviewChanged: ((ScreenshotShelfDragPreview?) -> Void)?

    init(layout: ScreenshotShelfLayout = .empty) {
        self.layout = layout
    }

    func perform(_ action: ScreenshotShelfAction) {
        delegate?.screenshotShelfViewModel(self, perform: action)
    }

    func setFocusedCapture(_ captureID: UUID?) {
        guard focusedCaptureID != captureID else { return }
        focusedCaptureID = captureID
    }

#if DEBUG
    /// Showcase hooks for the documentation exporter. Shipping code never calls these.
    func setDragPreviewForShowcase(_ preview: ScreenshotShelfDragPreview?) {
        dragPreview = preview
    }

    func setPointerForShowcase(inside: Bool, location: CGPoint?) {
        isPointerInside = inside
        pointerLocation = location
    }
#endif

    func beginDrag(cardID: UUID, startIndex: Int, startX: CGFloat, width: CGFloat) {
        delegate?.screenshotShelfViewModel(self, perform: .beginInteraction)
        let preview = ScreenshotShelfDragPreview(
            cardID: cardID,
            startIndex: startIndex,
            startX: startX,
            width: width,
            translation: .zero,
            rotation: 0
        )
        dragPreview = preview
        onDragPreviewChanged?(preview)
    }

    func updateDrag(_ preview: ScreenshotShelfDragPreview) {
        guard dragPreview != nil else { return }
        dragPreview = preview
        onDragPreviewChanged?(preview)
    }

    func endDrag() {
        guard dragPreview != nil else { return }
        dragPreview = nil
        onDragPreviewChanged?(nil)
        delegate?.screenshotShelfViewModel(self, perform: .endInteraction)
    }

    /// Called by the panel's native tracking area. This is the source of truth for hover,
    /// because SwiftUI `onHover` is unreliable on a non-key accessory panel.
    func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        onPointerInsideChanged?(inside)
    }

    func setPointerLocation(_ location: CGPoint?) {
        pointerLocation = location
    }
}
