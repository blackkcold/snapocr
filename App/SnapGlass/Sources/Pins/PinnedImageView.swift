import AppKit
import CaptureCore

// MARK: - PinnedImageView

@MainActor
final class PinnedImageView: NSView {
    private let image: CGImage
    private let displayScale: CGFloat
    private let onRequestClose: () -> Void
    private let onCopyImage: () -> Void
    private let onCopyOCRText: () -> Void
    private let onCloseAll: () -> Void

    private let alphaMask: [UInt8]?
    private let alphaMaskWidth: Int
    private let alphaMaskHeight: Int

    private var opacity: CGFloat = 1
    private var dragStartLocation: CGPoint?
    private var dragStartFrame: CGRect?
    private var isResizing = false
    private var isHovering = false
    private var trackingAreaReference: NSTrackingArea?

    /// 悬停状态变化回调，驱动悬浮工具条显隐。
    var onHoverChanged: ((Bool) -> Void)?

    /// 不透明度变化回调，用于把滚轮/⌥+滚轮的结果同步回工具条滑杆。
    var onOpacityChanged: ((CGFloat) -> Void)?

    /// 当前缩放倍率。
    ///
    /// 由面板 frame 宽度反推，不存在可变副本——`fitToScreen()` 与拖拽缩放只改 frame，
    /// 若另行缓存倍率就会与画面失同步（工具条读数随之失真）。
    var currentScale: CGFloat {
        guard let window else { return 1 }
        return PinnedImageGeometry.scale(
            frameWidth: window.frame.width,
            imagePixelWidth: CGFloat(image.width),
            displayScale: displayScale
        )
    }

    /// 当前不透明度。
    var currentOpacity: CGFloat { opacity }

    private static let closeButtonSize: CGFloat = 20
    private static let resizeHitInset: CGFloat = 14
    private static let alphaMaskMaxDimension = 256
    private static let alphaHitThreshold: CGFloat = 0.05
    private static let minimumResizeWidth: CGFloat = 40

    init(
        image: CGImage,
        displayScale: CGFloat,
        onRequestClose: @escaping () -> Void,
        onCopyImage: @escaping () -> Void,
        onCopyOCRText: @escaping () -> Void,
        onCloseAll: @escaping () -> Void
    ) {
        self.image = image
        self.displayScale = displayScale > 0 ? displayScale : 1
        self.onRequestClose = onRequestClose
        self.onCopyImage = onCopyImage
        self.onCopyOCRText = onCopyOCRText
        self.onCloseAll = onCloseAll
        let mask = Self.makeAlphaMask(image)
        self.alphaMask = mask?.alpha
        self.alphaMaskWidth = mask?.width ?? 0
        self.alphaMaskHeight = mask?.height ?? 0
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        onHoverChanged?(false)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if resizeHandleRect().contains(point) {
            NSCursor.crosshair.set()
        } else if closeButtonRect().contains(point) {
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    /// alpha 感知命中：透明区域不接受事件，避免遮挡下方内容。
    ///
    /// 关闭按钮与缩放手柄始终可命中——自由圈选截图的角落可能是透明的，
    /// 否则用户无法点击它们。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if closeButtonRect().contains(point) || resizeHandleRect().contains(point) {
            return self
        }
        guard alphaAt(point: point) > Self.alphaHitThreshold else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()

        if isHovering {
            context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1)
            context.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
            drawCloseButton(in: context)
        }
    }

    private func drawCloseButton(in context: CGContext) {
        let rect = closeButtonRect()
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        let inset = rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.32)
        context.move(to: CGPoint(x: inset.minX, y: inset.minY))
        context.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        context.move(to: CGPoint(x: inset.minX, y: inset.maxY))
        context.addLine(to: CGPoint(x: inset.maxX, y: inset.minY))
        context.strokePath()
    }

    private func closeButtonRect() -> CGRect {
        let size = Self.closeButtonSize
        return CGRect(
            x: bounds.maxX - size - 6,
            y: bounds.maxY - size - 6,
            width: size,
            height: size
        )
    }

    private func resizeHandleRect() -> CGRect {
        CGRect(
            x: bounds.maxX - Self.resizeHitInset,
            y: bounds.minY,
            width: Self.resizeHitInset,
            height: Self.resizeHitInset
        )
    }

    // MARK: - 拖动与缩放

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeButtonRect().contains(point) {
            onRequestClose()
            return
        }
        if event.clickCount == 2 {
            onRequestClose()
            return
        }
        dragStartLocation = NSEvent.mouseLocation
        dragStartFrame = window?.frame
        isResizing = resizeHandleRect().contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startLocation = dragStartLocation, let startFrame = dragStartFrame else { return }
        // 用屏幕坐标而非 locationInWindow：窗口移动后 locationInWindow 会随之偏移，
        // 造成拖拽反馈抖动。
        let current = NSEvent.mouseLocation
        let deltaX = current.x - startLocation.x
        let deltaY = current.y - startLocation.y

        if isResizing {
            let newWidth = max(Self.minimumResizeWidth, startFrame.width + deltaX)
            let aspect = CGFloat(image.width) / CGFloat(image.height)
            applyFrame(
                CGRect(
                    x: startFrame.minX,
                    y: startFrame.minY,
                    width: newWidth,
                    height: newWidth / aspect
                ),
                window: window
            )
        } else {
            window.setFrameOrigin(
                CGPoint(x: startFrame.origin.x + deltaX, y: startFrame.origin.y + deltaY)
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartFrame = nil
        isResizing = false
    }

    /// 滚轮缩放；按住 ⌥ 时改为调节透明度。
    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
        if event.modifierFlags.contains(.option) {
            opacity = PinnedImageGeometry.clampedOpacity(opacity - event.scrollingDeltaY * 0.01)
            window.alphaValue = opacity
            needsDisplay = true
            onOpacityChanged?(opacity)
            return
        }
        let newScale = PinnedImageGeometry.clampedScale(currentScale + event.scrollingDeltaY * 0.01)
        applyScale(newScale, window: window, anchor: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        let newScale = PinnedImageGeometry.clampedScale(currentScale * (1 + event.magnification))
        applyScale(newScale, window: window, anchor: convert(event.locationInWindow, from: nil))
    }

    /// 以光标为锚点缩放，保持光标下的内容位置不动。
    private func applyScale(_ newScale: CGFloat, window: NSWindow, anchor: CGPoint) {
        let current = currentScale
        guard current > 0, newScale != current else { return }
        let ratio = newScale / current
        let frame = window.frame
        applyFrame(
            CGRect(
                x: frame.minX + anchor.x * (1 - ratio),
                y: frame.minY + anchor.y * (1 - ratio),
                width: frame.width * ratio,
                height: frame.height * ratio
            ),
            window: window
        )
    }

    /// 统一的 frame 变更入口：写入前先把倍率收敛到允许区间。
    ///
    /// 拖拽缩放允许的最小宽度可能对应低于 `minimumScale` 的倍率，若不收敛，
    /// 工具条读数会落在滑杆量程之外且与画面不一致。
    private func applyFrame(_ frame: CGRect, window: NSWindow) {
        let limited = PinnedImageGeometry.clampFrameToScaleRange(
            frame,
            imagePixelWidth: CGFloat(image.width),
            displayScale: displayScale
        )
        window.setFrame(limited, display: true)
        needsDisplay = true
    }

    /// 恢复到原始点尺寸（1:1）。
    func resetToOriginalSize() {
        guard let window else { return }
        applyFrame(
            CGRect(
                origin: window.frame.origin,
                size: CGSize(
                    width: CGFloat(image.width) / displayScale,
                    height: CGFloat(image.height) / displayScale
                )
            ),
            window: window
        )
    }

    func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        applyFrame(
            PinnedImageGeometry.fitToScreen(window.frame, screenFrame: screen.visibleFrame),
            window: window
        )
    }

    /// 设置不透明度（供工具条滑杆使用），与 `⌥`+滚轮共用同一条路径。
    func setOpacity(_ newOpacity: CGFloat) {
        guard let window else { return }
        opacity = PinnedImageGeometry.clampedOpacity(newOpacity)
        window.alphaValue = opacity
        needsDisplay = true
        onOpacityChanged?(opacity)
    }

    /// 设置缩放倍率（供工具条滑杆使用），以面板中心为锚点。
    func setScale(_ newScale: CGFloat) {
        guard let window else { return }
        applyScale(
            PinnedImageGeometry.clampedScale(newScale),
            window: window,
            anchor: CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        )
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(
            withTitle: AppLocalization.string("Copy Image"),
            action: #selector(copyImage),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: AppLocalization.string("Copy Text (OCR)"),
            action: #selector(copyOCRText),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: AppLocalization.string("Scale"),
            action: #selector(resetScale),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: AppLocalization.string("Fit to Screen"),
            action: #selector(fitToScreenAction),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: AppLocalization.string("Close All Pinned Images"),
            action: #selector(closeAll),
            keyEquivalent: ""
        ).target = self
        return menu
    }

    @objc private func copyImage() { onCopyImage() }
    @objc private func copyOCRText() { onCopyOCRText() }
    @objc private func resetScale() { resetToOriginalSize() }
    @objc private func fitToScreenAction() { fitToScreen() }
    @objc private func closeAll() { onCloseAll() }

    // MARK: - Alpha 掩码

    private func alphaAt(point: CGPoint) -> CGFloat {
        guard let alphaMask, alphaMaskWidth > 0, alphaMaskHeight > 0,
              bounds.width > 0, bounds.height > 0 else { return 1 }
        let normalizedX = min(max(point.x / bounds.width, 0), 0.9999)
        let normalizedY = min(max(point.y / bounds.height, 0), 0.9999)
        let column = Int(normalizedX * CGFloat(alphaMaskWidth))
        let row = Int((1 - normalizedY) * CGFloat(alphaMaskHeight))
        let index = row * alphaMaskWidth + column
        guard index >= 0, index < alphaMask.count else { return 1 }
        return CGFloat(alphaMask[index]) / 255
    }

    /// 预渲染降采样 alpha 掩码，避免依赖 `CGImage` 的字节序与 `alphaInfo` 组合。
    private static func makeAlphaMask(_ image: CGImage) -> AlphaMask? {
        let longest = max(image.width, image.height)
        let ratio = min(1, CGFloat(alphaMaskMaxDimension) / CGFloat(max(1, longest)))
        let width = max(1, Int(CGFloat(image.width) * ratio))
        let height = max(1, Int(CGFloat(image.height) * ratio))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            alpha[index] = pixels[index * 4 + 3]
        }
        return AlphaMask(alpha: alpha, width: width, height: height)
    }
}

/// 降采样 Alpha 掩码，用于 alpha 感知命中测试。
private struct AlphaMask {
    let alpha: [UInt8]
    let width: Int
    let height: Int
}
