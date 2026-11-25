import AnnotationCore
import AppKit
import CaptureCore
import CoreText
import OCRCore
import SharedKit
import SwiftUI

/// 画布渲染尺寸的量化档位。
///
/// 连续缩放时显示尺寸每帧都变，直接拿它当缓存键会让 5K 底图每帧重新
/// 降采样 + 重新合成。吸附到档位后，只有跨档才重新渲染。
enum CanvasRenderScale {
    static let steps: [CGFloat] = [512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192]

    static func quantize(_ value: CGFloat) -> CGFloat {
        guard value > 0 else { return value }
        return steps.first { $0 >= value } ?? value
    }
}

/// Base image resampled for the current on-screen size.
struct CanvasBaseDisplayCache {
    let source: CGImage
    let maxDimension: CGFloat
    let image: CGImage
}

final class EditableAnnotationCanvasNSView: NSView {
    var image: CGImage? {
        didSet {
            // 底图换了以后同一像素坐标对应的是另一块颜色，缓存的取色键必须作废。
            pickerSampleKey = ""
            prepareVerticalCropIfNeeded()
        }
    }
    var nodes: [AnnotationNode] = []
    var currentTool: EditorTool = .select {
        didSet {
            if currentTool != .ocr, currentTool != .select {
                ocrTextSelection = nil
            }
            if oldValue == .crop, currentTool != .crop {
                cancelPendingCrop()
            }
            if currentTool != .picker, pickerHoverColor != nil || !pickerLabelRect.isEmpty {
                // 换工具时只擦掉取色标签那一块，避免残留到下一次整画布重绘。
                let dirty = pickerLabelRect.insetBy(dx: -2, dy: -2)
                pickerHoverColor = nil
                pickerLabelRect = .zero
                pickerSampleKey = ""
                pickerPendingWorkItem?.cancel()
                pickerPendingWorkItem = nil
                pickerPendingPoint = nil
                if !dirty.isEmpty { setNeedsDisplay(dirty) }
            }
            prepareVerticalCropIfNeeded()
            window?.invalidateCursorRects(for: self)
        }
    }
    var verticalCropOnly = false {
        didSet {
            if oldValue != verticalCropOnly {
                cancelPendingCrop()
            }
            prepareVerticalCropIfNeeded()
        }
    }
    var currentColor = Palette.defaultAnnotationColor
    var currentLineWidth: CGFloat = 3
    var currentOpacity: CGFloat = 1
    var currentFillColor: CGColor?
    var currentStrokeStyle: AnnotationStrokeStyle = .solid
    var currentCornerRadius: CGFloat = 0
    var currentArrowStyle: AnnotationArrowStyle = .filled
    var currentFontName = "Helvetica"
    var currentFontSize: CGFloat = 24
    var currentTextAlignment: AnnotationTextAlignment = .leading
    var currentBlurMode: AnnotationBlurMode = .gaussian
    var currentBlurIntensity: CGFloat = 0.5
    var selectedNodeID: UUID? {
        didSet {
            if oldValue != selectedNodeID {
                hoveredHandle = nil
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    /// 当前悬停的缩放手柄；只影响手柄本身的绘制与光标。
    var hoveredHandle: ResizeHandle?
    var ocrLines: [OCRLine] = []
    var showsOCROverlay = true {
        didSet {
            if !showsOCROverlay {
                ocrTextSelection = nil
            }
            window?.invalidateCursorRects(for: self)
        }
    }

    var onNodeCreated: ((AnnotationNode) -> Void)?
    var onNodeUpdated: ((AnnotationNode) -> Void)?
    var onSelectionChanged: ((UUID?) -> Void)?
    var onDeleteSelection: (() -> Void)?
    var onTextRequested: ((CGPoint) -> Void)?
    var onTextEditRequested: ((AnnotationNode) -> Void)?
    var onOCRLinesCopied: (([OCRLine]) -> Void)?
    var onOCRTextCopied: ((String) -> Void)?
    var onOCRLineAsAnnotation: ((OCRLine) -> Void)?
    var onColorPicked: ((SampledColor) -> Void)?
    var onRegionColorsPicked: (([SampledColor]) -> Void)?

    enum Interaction {
        case none
        case drawing
        case moving
        case resizing(ResizeHandle)
        case selectingOCRText
        case adjustingCrop
        case movingCrop
        case resizingCrop(ResizeHandle)
        case panning
    }

    enum ResizeHandle: CaseIterable, Equatable {
        case bottomLeft, bottom, bottomRight, right
        case topRight, top, topLeft, left
        case start, end
    }

    var imageDisplayRect: CGRect = .zero
    /// Share appearance drawn around the image. `nil` keeps the bare-image
    /// canvas; every geometry consumer still reads `imageDisplayRect`.
    var shareStyle: MockupStyle?
    /// Zoom relative to the fit-to-window frame; 1 shows the whole canvas.
    var zoomScale: CGFloat = 1
    /// Pan offset in view points, applied after zoom.
    var panOffset: CGSize = .zero
    /// Fit rect of the whole treatment frame at zoom 1.
    var fitCanvasRect: CGRect = .zero
    /// Fit rect of the image content at zoom 1, used by 1:1 and pixel labels.
    var fitImageRect: CGRect = .zero
    var lastImageSize: CGSize = .zero
    /// True while the space bar is held for drag-to-pan.
    var isSpacePanning = false
    /// Reports (zoom relative to fit, scale relative to image pixels).
    var onZoomChanged: ((CGFloat, CGFloat) -> Void)?
    /// Invoked when the user presses a single-key tool shortcut.
    var onToolShortcut: ((EditorTool) -> Void)?
    var interaction: Interaction = .none
    var dragStartPoint: CGPoint = .zero
    var dragCurrentPoints: [CGPoint] = []
    var dragCurrentRect: CGRect = .zero
    var pendingCropRect: CGRect = .zero
    var cropInteractionStartRect: CGRect = .zero
    var originalNode: AnnotationNode?
    var interactiveNode: AnnotationNode?
    /// The node whose style is being dragged in the inspector. It is excluded
    /// from the cached preview and painted live, so a slider tick never forces
    /// a full-image recomposite.
    var liveStyleNodeID: UUID?
    var renderedPreview: CGImage?
    var renderedPreviewNodes: [AnnotationNode]?
    var renderedPreviewSource: CGImage?
    var renderedPreviewBase: CGImage?
    var renderedPreviewMaxDimension: CGFloat = 0
    var baseDisplayCache: CanvasBaseDisplayCache?
    var contextualOCRLine: OCRLine?
    var ocrTextSelection: OCRTextSelection?
    var ocrContentSignature = ""
    /// OCR 行顺序缓存：`orderedOCRLines` 原来是一帧内被求值多次的 filter + sort。
    var ocrOrderedLinesCache: [OCRLine]?
    /// OCR 每行的排版缓存（CTLine + 字体度量），按 ordered 索引存放，
    /// 内容签名变化或行框尺寸变化时失效。
    var ocrTextLineCache: [Int: OCRTextLineCache] = [:]

    /// 一行 OCR 文本的排版缓存。
    struct OCRTextLineCache {
        let size: CGSize
        let line: CTLine
        let measuredWidth: CGFloat
    }
    var resizePointerOffset: CGPoint = .zero
    private var trackingAreaReference: NSTrackingArea?
    var hoverPoint: CGPoint = .zero
    var pickerHoverColor: SampledColor?
    var pickerRegionRect: CGRect = .zero
    /// 上一次取色的时间戳（30Hz 限流）与同一像素判定。
    var pickerLastSampleTime: CFTimeInterval = 0
    var pickerSampleKey: String = ""
    var pickerPendingPoint: CGPoint?
    var pickerPendingWorkItem: DispatchWorkItem?
    /// 色值标签当前占用的矩形，用于只失效这一块而不是整张画布。
    var pickerLabelRect: CGRect = .zero
    /// 标签实际绘制所依据的光标位置。绘制必须用它而不是 `hoverPoint`：
    /// 限流期间 `hoverPoint` 会继续前进，用它会画出没有被失效过的残影。
    var pickerLabelPoint: CGPoint = .zero
    var dominantColorCount = 5
    var canvasTextEditor: CanvasTextEditor?
    var canvasTextEntryID: UUID?
    /// Mirrors the inline editor's text into the view model so closing the
    /// window while typing still sees unsaved content.
    var onTextDraftChanged: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverPoint = point
        if currentTool == .select {
            updateHoveredHandle(at: point)
        }
        // Only the picker paints anything that follows the cursor. Other tools
        // used to redraw the whole canvas on every mouse move for nothing.
        guard currentTool == .picker else { return }
        schedulePickerSample(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredHandle != nil else { return }
        let dirty =
            hoveredHandle.flatMap { handle in
                selectedNode.map { handleInvalidationRect(handle, for: $0) }
            } ?? .null
        hoveredHandle = nil
        if !dirty.isNull {
            setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2))
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if currentTool == .ocr || currentTool == .select, showsOCROverlay {
            for line in orderedOCRLines {
                addCursorRect(
                    viewRect(from: line.editorBoundingBox).insetBy(dx: -3, dy: -3),
                    cursor: .iBeam
                )
            }
        }
        // 最后添加缩放手柄，让它在与 OCR 文本重叠时优先：
        // 手柄命中范围更大，用户此时想调整标注而不是选文本。
        if currentTool == .select, let node = selectedNode {
            for handle in visibleHandles(for: node) {
                let center = handlePoint(handle, for: node)
                addCursorRect(
                    CGRect(
                        x: center.x - DS.Hit.handle / 2,
                        y: center.y - DS.Hit.handle / 2,
                        width: DS.Hit.handle,
                        height: DS.Hit.handle
                    ),
                    cursor: Self.cursor(for: handle)
                )
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(bounds)

        if let image {
            let imageSize = CGSize(width: image.width, height: image.height)
            lastImageSize = imageSize
            let layout = mockupLayout(for: imageSize)
            let frame = canvasRect(for: imageSize)
            let frameScale = frame.width / max(layout.canvasSize.width, 1)
            imageDisplayRect = layout.contentRect(in: frame.origin, scale: frameScale)

            let backingScale = window?.backingScaleFactor ?? 2
            // The annotated preview only follows the document. Sizing it from
            // the treatment frame, floored by the view, keeps it stable while
            // padding/radius/shadow sliders move.
            let reference = max(frame.width, frame.height, bounds.width, bounds.height)
            let targetMaxDimension = min(
                CanvasRenderScale.quantize(reference * backingScale),
                CGFloat(max(image.width, image.height))
            )
            let baseImage = baseDisplayImage(for: image, targetMaxDimension: targetMaxDimension)
            let displayImage =
                previewImage(
                    for: image,
                    baseImage: baseImage,
                    maximumDimension: targetMaxDimension
                ) ?? baseImage

            if let style = shareStyle {
                if style.background.isTransparent {
                    drawCheckerboard(in: frame, context: context)
                }
                // The same layout and draw call the exporter uses, so the canvas
                // is the export rather than an approximation of it. The backdrop
                // returns to view space so its tiles keep the same 8 pt size and
                // phase as the padding checkerboard.
                let viewTransform = context.ctm
                MockupRenderer.draw(
                    displayImage,
                    style: style,
                    layout: layout,
                    in: context,
                    origin: frame.origin,
                    scale: frameScale,
                    backdrop: { [weak self] context, _ in
                        guard let self else { return }
                        context.saveGState()
                        context.concatenate(context.ctm.inverted())
                        context.concatenate(viewTransform)
                        self.drawCheckerboard(in: frame, context: context)
                        context.restoreGState()
                    }
                )
            } else {
                context.draw(displayImage, in: imageDisplayRect)
            }

            // The node being dragged or resized is excluded from the cached
            // preview and drawn live, so a drag never re-renders the whole image.
            if let interactiveNode, interactiveNode.tool != .blur {
                drawInteractiveNode(interactiveNode, in: context, imageSize: imageSize)
            }

            // A style slider behaves the same way: the rest of the document
            // stays on the cached bitmap while only the edited node is redrawn.
            if let liveStyleNodeID,
                let liveStyleNode = nodes.first(where: { $0.id == liveStyleNodeID }),
                liveStyleNode.tool != .blur,
                liveStyleNode.id != interactiveNode?.id
            {
                drawInteractiveNode(liveStyleNode, in: context, imageSize: imageSize)
            }
        } else {
            imageDisplayRect = bounds
        }

        if showsOCROverlay {
            drawOCROverlay(in: context)
        }
        if case .drawing = interaction {
            drawCreationPreview(in: context)
        }
        drawPendingCrop(in: context)
        drawSelection(in: context)
        if currentTool == .picker {
            drawPickerOverlay(in: context)
        }
    }

    /// Cached 16×16 checkerboard used behind transparent share backgrounds.
    private static let checkerTile: CGImage? = {
        let size = 16
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let base = CGColor(colorSpace: space, components: [0.17, 0.17, 0.17, 1]) ?? CGColor(gray: 0.17, alpha: 1)
        let alternate =
            CGColor(colorSpace: space, components: [0.23, 0.23, 0.23, 1])
            ?? CGColor(gray: 0.23, alpha: 1)
        context.setFillColor(base)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(alternate)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        return context.makeImage()
    }()

    /// Paints the transparency checkerboard inside `rect`.
    func drawCheckerboard(in rect: CGRect, context: CGContext) {
        guard !rect.isEmpty else { return }
        guard let tile = Self.checkerTile else {
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(rect)
            return
        }
        context.saveGState()
        context.clip(to: rect)
        context.draw(tile, in: rect, byTiling: true)
        context.restoreGState()
    }

    private func drawPickerOverlay(in context: CGContext) {
        if !pickerRegionRect.isEmpty {
            context.saveGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(pickerRegionRect)
            context.restoreGState()
        }
        if let pickerHoverColor {
            drawColorLabel(pickerHoverColor, near: pickerLabelPoint)
        }
    }

    /// 字体只创建一次：每次 mouseMoved 都新建 NSFont 会让取色标签成为热路径上的分配点。
    private static let colorLabelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private static let colorLabelSecondaryFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    private static let colorLabelSwatchSize: CGFloat = 10
    private static let colorLabelSwatchPadding: CGFloat = 5
    private static let colorLabelTextPadding: CGFloat = 6

    /// 色值标签的包围盒。抽出来是为了在绘制前就能算出需要失效的区域。
    ///
    /// 靠近右缘/上缘时翻到光标另一侧，再夹进可见区域；否则标签会被裁掉，
    /// 而失效矩形仍按旧位置算，边上会留下残影。
    func colorLabelRect(for color: SampledColor, near point: CGPoint) -> CGRect {
        let hexSize = (color.hexString as NSString).size(withAttributes: [.font: Self.colorLabelFont])
        let rgbSize = (color.rgbString as NSString).size(withAttributes: [.font: Self.colorLabelSecondaryFont])
        let lineHeight = max(hexSize.height, rgbSize.height)
        let textWidth = max(hexSize.width, rgbSize.width)
        let size = CGSize(
            width: Self.colorLabelSwatchSize
                + Self.colorLabelSwatchPadding
                + textWidth
                + Self.colorLabelTextPadding * 2,
            height: lineHeight * 2 + 8
        )
        let placementRect =
            shareStyle == nil
            ? imageDisplayRect
            : canvasRect(for: lastImageSize)
        let visible = bounds.intersection(placementRect)
        let placementBounds = visible.isNull || visible.isEmpty ? bounds : visible
        return LabelPlacement.rect(size: size, near: point, inside: placementBounds)
    }

    private func drawColorLabel(_ color: SampledColor, near point: CGPoint) {
        guard imageDisplayRect.contains(point) else { return }
        let hexLabel = color.hexString
        let rgbLabel = color.rgbString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.colorLabelFont,
            .foregroundColor: NSColor.white,
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.colorLabelSecondaryFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let hexSize = (hexLabel as NSString).size(withAttributes: attributes)
        let swatchSize = Self.colorLabelSwatchSize
        let swatchPadding = Self.colorLabelSwatchPadding
        let rect = colorLabelRect(for: color, near: point)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let swatchRect = CGRect(
            x: rect.minX + 6,
            y: rect.midY - swatchSize / 2,
            width: swatchSize,
            height: swatchSize
        )
        NSColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        ).setFill()
        NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2).stroke()
        let textX = swatchRect.maxX + swatchPadding
        let hexBaseline = rect.maxY - 4 - hexSize.height
        let rgbBaseline = rect.minY + 4
        (hexLabel as NSString).draw(at: CGPoint(x: textX, y: hexBaseline), withAttributes: attributes)
        (rgbLabel as NSString).draw(at: CGPoint(x: textX, y: rgbBaseline), withAttributes: secondaryAttributes)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
