import AnnotationCore
import AppKit
import CoreText
import OCRCore
import SharedKit
import SwiftUI

final class EditableAnnotationCanvasNSView: NSView {
    var image: CGImage? {
        didSet { prepareVerticalCropIfNeeded() }
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
    var currentColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
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
    var selectedNodeID: UUID?
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
    }

    enum ResizeHandle: CaseIterable, Equatable {
        case bottomLeft, bottom, bottomRight, right
        case topRight, top, topLeft, left
        case start, end
    }

    var imageDisplayRect: CGRect = .zero
    var interaction: Interaction = .none
    var dragStartPoint: CGPoint = .zero
    var dragCurrentPoints: [CGPoint] = []
    var dragCurrentRect: CGRect = .zero
    var pendingCropRect: CGRect = .zero
    var cropInteractionStartRect: CGRect = .zero
    var originalNode: AnnotationNode?
    var interactiveNode: AnnotationNode?
    var renderedPreview: CGImage?
    var contextualOCRLine: OCRLine?
    var ocrTextSelection: OCRTextSelection?
    var ocrContentSignature = ""
    var resizePointerOffset: CGPoint = .zero
    private var trackingAreaReference: NSTrackingArea?
    private var hoverPoint: CGPoint = .zero
    var pickerHoverColor: SampledColor?
    var pickerRegionRect: CGRect = .zero
    var dominantColorCount = 5

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        pickerHoverColor = currentTool == .picker ? sampledColor(at: hoverPoint) : nil
        needsDisplay = true
    }

    /// Samples the color under a view point in the base image.
    func sampledColor(at point: CGPoint) -> SampledColor? {
        guard let image, imageDisplayRect.contains(point) else { return nil }
        let normalized = normalizedPoint(point)
        let pixel = CGPoint(
            x: normalized.x * CGFloat(image.width),
            y: (1 - normalized.y) * CGFloat(image.height)
        )
        return ColorSampler.pixelColor(in: image, at: pixel)
    }

    /// Samples the dominant colors over a view-space region.
    func sampledRegionColors(for viewRect: CGRect) -> [SampledColor] {
        guard let image, !viewRect.isEmpty else { return [] }
        let normalized = CGRect(
            x: (viewRect.minX - imageDisplayRect.minX) / imageDisplayRect.width,
            y: (viewRect.minY - imageDisplayRect.minY) / imageDisplayRect.height,
            width: viewRect.width / imageDisplayRect.width,
            height: viewRect.height / imageDisplayRect.height
        )
        let pixelRect = CGRect(
            x: normalized.minX * CGFloat(image.width),
            y: (1 - normalized.maxY) * CGFloat(image.height),
            width: normalized.width * CGFloat(image.width),
            height: normalized.height * CGFloat(image.height)
        )
        return ColorSampler.dominantColors(in: image, in: pixelRect, count: dominantColorCount)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard currentTool == .ocr || currentTool == .select, showsOCROverlay else { return }
        for line in orderedOCRLines {
            addCursorRect(
                viewRect(from: line.editorBoundingBox).insetBy(dx: -3, dy: -3),
                cursor: .iBeam
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(bounds)

        if let image {
            let displayImage = previewImage(for: image) ?? image
            imageDisplayRect = aspectFitRect(
                imageSize: CGSize(width: displayImage.width, height: displayImage.height),
                in: bounds
            )
            context.draw(displayImage, in: imageDisplayRect)
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
            drawColorLabel(pickerHoverColor, near: hoverPoint)
        }
    }

    private func drawColorLabel(_ color: SampledColor, near point: CGPoint) {
        guard imageDisplayRect.contains(point) else { return }
        let hexLabel = color.hexString
        let rgbLabel = color.rgbString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let hexSize = (hexLabel as NSString).size(withAttributes: attributes)
        let rgbSize = (rgbLabel as NSString).size(withAttributes: secondaryAttributes)
        let swatchSize: CGFloat = 10
        let swatchPadding: CGFloat = 5
        let textPadding: CGFloat = 6
        let lineHeight = max(hexSize.height, rgbSize.height)
        let textWidth = max(hexSize.width, rgbSize.width)
        let rect = CGRect(
            x: point.x + 14,
            y: point.y + 14,
            width: swatchSize + swatchPadding + textWidth + textPadding * 2,
            height: lineHeight * 2 + 8
        )
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
}
