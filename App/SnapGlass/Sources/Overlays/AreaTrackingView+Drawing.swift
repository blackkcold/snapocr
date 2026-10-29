import AppKit
import CaptureCore
import SharedKit
import SwiftUI

@preconcurrency import ScreenCaptureKit

// MARK: - AreaTrackingView 绘制

extension AreaTrackingView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        switch overlayMode {
        case .live:
            drawLiveBackground(in: context)
        case .snapshot:
            drawSnapshotBackground(in: context)
        }

        drawSelectionOutline(in: context)

        if !selectionRect.isEmpty {
            drawSizeLabel(for: selectionRect)
        }
        drawCrosshair(at: hoverPoint)
        if let hoverColor { drawHoverColorLabel(for: hoverColor, near: hoverPoint) }
    }

    private func drawLiveBackground(in context: CGContext) {
        context.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        context.fill(bounds)

        context.saveGState()
        guard clipToSelection(in: context) else {
            context.restoreGState()
            return
        }
        context.clear(bounds)
        context.restoreGState()
    }

    private func drawSnapshotBackground(in context: CGContext) {
        guard let snapshotFrame else {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)
            return
        }

        draw(snapshotFrame, in: context)
        context.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        context.fill(bounds)

        context.saveGState()
        guard clipToSelection(in: context) else {
            context.restoreGState()
            return
        }
        draw(snapshotFrame, in: context)
        context.restoreGState()
    }

    private var snapshotFrame: CGImage? {
        guard bounds.width > 0, bounds.height > 0,
              let displayID = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? CGDirectDisplayID,
              let frame = capturedFrames[displayID]
        else { return nil }

        let viewAspectRatio = bounds.width / bounds.height
        let frameAspectRatio = CGFloat(frame.width) / CGFloat(frame.height)
        let relativeDifference = abs(frameAspectRatio - viewAspectRatio) / viewAspectRatio
        return relativeDifference <= 0.02 ? frame : nil
    }

    private func draw(_ image: CGImage, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(
            x: bounds.width / CGFloat(image.width),
            y: bounds.height / CGFloat(image.height)
        )
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
        context.restoreGState()
    }

    private func clipToSelection(in context: CGContext) -> Bool {
        if style == .freeform, freeformPoints.count >= 2 {
            context.addPath(freeformPath())
            context.clip()
            return true
        }
        guard !selectionRect.isEmpty else { return false }
        context.clip(to: selectionRect)
        return true
    }

    private func drawSelectionOutline(in context: CGContext) {
        if style == .freeform, freeformPoints.count >= 2 {
            let path = freeformPath()
            // 深色衬边 + 白色内描边：单白线在白底网页/浅色 PDF 上几乎不可见。
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(3)
            context.addPath(path)
            context.strokePath()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.addPath(path)
            context.strokePath()
        } else if !selectionRect.isEmpty {
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(3)
            context.stroke(selectionRect.insetBy(dx: -1.5, dy: -1.5))
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            context.stroke(selectionRect.insetBy(dx: -1, dy: -1))
            if phase == .selected { drawHandles() }
        }
    }

    /// Samples the pixel directly beneath a view point from the pre-captured
    /// frame for the screen this panel covers.
    func sampleColor(at viewPoint: CGPoint) -> SampledColor? {
        guard let window,
              let displayID = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? CGDirectDisplayID,
              let frame = capturedFrames[displayID]
        else { return nil }

        let viewRect = CGRect(origin: viewPoint, size: .zero)
        let windowRect = convert(viewRect, to: nil)
        let appKitRect = window.convertToScreen(windowRect)
        let center = CGPoint(x: appKitRect.midX, y: appKitRect.midY)

        // Convert the AppKit global point to Quartz, then to a local offset
        // within this screen's frame, then to pixel coordinates in the image.
        guard
            let quartzPoint = ScreenCoordinateGeometry.quartzPoint(
                from: center,
                appKitScreenFrame: screen.frame,
                quartzScreenFrame: CGDisplayBounds(displayID)
            )
        else { return nil }

        let quartzFrame = CGDisplayBounds(displayID)
        let localX = quartzPoint.x - quartzFrame.minX
        let localY = quartzPoint.y - quartzFrame.minY
        let scaleX = CGFloat(frame.width) / quartzFrame.width
        let scaleY = CGFloat(frame.height) / quartzFrame.height
        let pixel = CGPoint(x: localX * scaleX, y: localY * scaleY)
        return ColorSampler.pixelColor(in: frame, at: pixel)
    }

    private func drawHoverColorLabel(for color: SampledColor, near point: CGPoint) {
        guard bounds.contains(point) else { return }
        let hexLabel = color.hexString
        let rgbLabel = color.rgbString
        let attributes = AreaHoverLabelMetrics.primaryAttributes
        let secondaryAttributes = AreaHoverLabelMetrics.secondaryAttributes
        let hexSize = AreaHoverLabelMetrics.hexSize(for: hexLabel)
        let rgbSize = AreaHoverLabelMetrics.rgbSize(for: rgbLabel)
        let swatchSize: CGFloat = 10
        let swatchPadding: CGFloat = 5
        let textPadding: CGFloat = 6
        let lineHeight = max(hexSize.height, rgbSize.height)
        let textWidth = max(hexSize.width, rgbSize.width)
        let labelSize = CGSize(
            width: swatchSize + swatchPadding + textWidth + textPadding * 2,
            height: lineHeight * 2 + 8
        )
        let rect = hoverLabelRect.isEmpty
            ? LabelPlacement.rect(
                size: labelSize,
                near: point,
                offset: CGSize(width: DS.Space.s16, height: DS.Space.s16),
                inside: bounds
            )
            : hoverLabelRect
        NSColor.black.withAlphaComponent(Palette.labelBackground).setFill()
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

    private func drawCrosshair(at point: CGPoint) {
        guard bounds.contains(point), let context = NSGraphicsContext.current?.cgContext else { return }
        let length: CGFloat = 18
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: point.x - length, y: point.y))
        context.addLine(to: CGPoint(x: point.x + length, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - length))
        context.addLine(to: CGPoint(x: point.x, y: point.y + length))
        context.strokePath()
    }

    private func drawHandles() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (handle, point) in handlePoints() {
            let isHovered = handle == hoveredHandle
            let scale: CGFloat = isHovered && !reduceMotion ? 1.2 : 1
            let size = DS.Control.handleVisualSize * scale
            let rect = CGRect(
                x: point.x - size / 2,
                y: point.y - size / 2,
                width: size,
                height: size
            )
            let path = NSBezierPath(ovalIn: rect)
            Palette.handleFill.setFill()
            path.fill()
            (isHovered ? Palette.handleHoverStroke : Palette.handleStroke).setStroke()
            path.lineWidth = isHovered ? 1.5 : 1
            path.stroke()
        }
    }

    private func drawSizeLabel(for rect: CGRect) {
        drawLabel("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: rect.midX, y: rect.maxY + 18))
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(
            x: point.x - size.width / 2 - 6,
            y: point.y - size.height / 2 - 4,
            width: size.width + 12,
            height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
    }
}
