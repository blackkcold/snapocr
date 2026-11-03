import CoreGraphics

/// 置顶面板的手动缩放方向。
public enum PinnedImageResizeDirection: Equatable, Sendable {
    /// 拖动左边缘。
    case left

    /// 拖动右边缘。
    case right

    /// 拖动上边缘。
    case top

    /// 拖动下边缘。
    case bottom

    /// 拖动左上角。
    case topLeft

    /// 拖动右上角。
    case topRight

    /// 拖动左下角。
    case bottomLeft

    /// 拖动右下角。
    case bottomRight

    /// 相对当前 frame 的固定锚点，坐标范围为 `0...1`。
    public var fixedAnchor: CGPoint {
        switch self {
        case .left:
            CGPoint(x: 1, y: 0.5)
        case .right:
            CGPoint(x: 0, y: 0.5)
        case .top:
            CGPoint(x: 0.5, y: 0)
        case .bottom:
            CGPoint(x: 0.5, y: 1)
        case .topLeft:
            CGPoint(x: 1, y: 0)
        case .topRight:
            CGPoint(x: 0, y: 0)
        case .bottomLeft:
            CGPoint(x: 1, y: 1)
        case .bottomRight:
            CGPoint(x: 0, y: 1)
        }
    }

    fileprivate var expansionVector: CGPoint {
        switch self {
        case .left:
            CGPoint(x: -1, y: 0)
        case .right:
            CGPoint(x: 1, y: 0)
        case .top:
            CGPoint(x: 0, y: 1)
        case .bottom:
            CGPoint(x: 0, y: -1)
        case .topLeft:
            CGPoint(x: -1, y: 1)
        case .topRight:
            CGPoint(x: 1, y: 1)
        case .bottomLeft:
            CGPoint(x: -1, y: -1)
        case .bottomRight:
            CGPoint(x: 1, y: -1)
        }
    }
}

/// 置顶图片面板上指针位置对应的交互类型。
public enum PinnedImageInteraction: Equatable, Sendable {
    /// 命中关闭按钮。
    case close

    /// 命中可缩放的边缘或角落。
    case resize(PinnedImageResizeDirection)

    /// 命中不透明图片内容，可拖动面板。
    case move

    /// 命中透明内容，应将事件交给下层窗口。
    case passThrough
}

/// 置顶面板的几何计算。
///
/// 全部以 AppKit 全局点坐标为单位（左下原点、Y 轴向上），与 `NSPanel.frame` 一致。
/// 缩放倍率由实际裁剪像素宽除以选区点宽得出，从而吸收 `.integral` 取整误差；
/// 多显示器混合缩放时各屏幕倍率不同，因此禁止用 `backingScaleFactor` 代替。
public enum PinnedImageGeometry {
    /// 允许的最小缩放倍率。
    public static let minimumScale: CGFloat = 0.1

    /// 允许的最大缩放倍率。
    public static let maximumScale: CGFloat = 8

    /// 允许的最小不透明度。
    public static let minimumOpacity: CGFloat = 0.2

    /// 允许的最大不透明度。
    public static let maximumOpacity: CGFloat = 1

    /// 多张置顶图级联时每级的偏移量（点）。
    public static let cascadeStep: CGFloat = 24

    /// 悬浮工具条与面板边缘的间距（点）。
    public static let toolbarSpacing: CGFloat = 8

    /// 边缘缩放命中区的默认宽度（点）。
    public static let resizeEdgeHitSize: CGFloat = 6

    /// 角落缩放命中区的默认边长（点）。
    public static let resizeCornerHitSize: CGFloat = 14

    /// 短边小于该值时，只启用自适应角落命中区（点）。
    public static let smallPanelResizeThreshold: CGFloat = 48

    private static let minimumSmallPanelMoveCoreSize: CGFloat = 12

    /// 计算置顶面板的初始 frame。
    ///
    /// 选区有效时直接使用原选区点矩形，实现「原位原尺寸」；选区无效时回退为
    /// 按真实缩放倍率换算的图片点尺寸，原点是零。
    ///
    /// - Parameters:
    ///   - appKitRect: 选区在 AppKit 全局点坐标中的矩形。
    ///   - imageSize: 裁剪后图片的像素尺寸。
    ///   - displayScale: 图片像素宽与选区点宽的比值。
    /// - Returns: 置顶面板初始 frame（AppKit 点坐标）。
    public static func initialPinFrame(
        appKitRect: CGRect,
        imageSize: CGSize,
        displayScale: CGFloat
    ) -> CGRect {
        guard appKitRect.width > 0, appKitRect.height > 0 else {
            let scale = displayScale > 0 ? displayScale : 1
            return CGRect(
                origin: .zero,
                size: CGSize(width: imageSize.width / scale, height: imageSize.height / scale)
            )
        }
        return appKitRect
    }

    /// 根据指针所在位置识别手动缩放方向。
    ///
    /// 角落命中优先于边缘；当面板短边小于 `smallPanelThreshold` 时关闭边缘热区，
    /// 并按两个轴分别缩小角落热区，避免缩放热区覆盖大部分面板中心。
    ///
    /// - Parameters:
    ///   - point: 面板局部坐标中的指针位置。
    ///   - frame: 面板局部坐标中的边界矩形。
    ///   - edgeHitSize: 边缘命中宽度。
    ///   - cornerHitSize: 角落命中区边长。
    ///   - smallPanelThreshold: 关闭边缘热区的短边阈值。
    /// - Returns: 命中的缩放方向；面板内部非热区或无效输入返回 `nil`。
    public static func resizeDirection(
        at point: CGPoint,
        in frame: CGRect,
        edgeHitSize: CGFloat = resizeEdgeHitSize,
        cornerHitSize: CGFloat = resizeCornerHitSize,
        smallPanelThreshold: CGFloat = smallPanelResizeThreshold
    ) -> PinnedImageResizeDirection? {
        guard frame.width > 0, frame.height > 0,
              frame.width.isFinite, frame.height.isFinite,
              frame.minX.isFinite, frame.minY.isFinite,
              point.x.isFinite, point.y.isFinite else { return nil }

        let distanceFromLeft = point.x - frame.minX
        let distanceFromRight = frame.maxX - point.x
        let distanceFromBottom = point.y - frame.minY
        let distanceFromTop = frame.maxY - point.y
        guard distanceFromLeft >= 0, distanceFromRight >= 0,
              distanceFromBottom >= 0, distanceFromTop >= 0 else { return nil }

        let cornerSize = max(0, cornerHitSize)
        if min(frame.width, frame.height) < max(0, smallPanelThreshold) {
            let horizontalHitSize = min(
                cornerSize,
                max(0, (frame.width - minimumSmallPanelMoveCoreSize) / 2)
            )
            let verticalHitSize = min(
                cornerSize,
                max(0, (frame.height - minimumSmallPanelMoveCoreSize) / 2)
            )
            return cornerDirection(
                left: distanceFromLeft,
                right: distanceFromRight,
                bottom: distanceFromBottom,
                top: distanceFromTop,
                hitSize: CGSize(width: horizontalHitSize, height: verticalHitSize)
            )
        }

        if let corner = cornerDirection(
            left: distanceFromLeft,
            right: distanceFromRight,
            bottom: distanceFromBottom,
            top: distanceFromTop,
            hitSize: CGSize(width: cornerSize, height: cornerSize)
        ) {
            return corner
        }

        let edgeSize = max(0, edgeHitSize)
        if distanceFromLeft <= edgeSize { return .left }
        if distanceFromRight <= edgeSize { return .right }
        if distanceFromBottom <= edgeSize { return .bottom }
        if distanceFromTop <= edgeSize { return .top }
        return nil
    }

    /// 按关闭按钮、缩放热区与图片透明度的优先级分类指针交互。
    ///
    /// 关闭按钮优先于重叠的角落热区，热区优先于 alpha 掩码；因此透明边缘仍可缩放，
    /// 只有不透明的面板内部才作为移动区域。
    ///
    /// - Parameters:
    ///   - point: 面板局部坐标中的指针位置。
    ///   - frame: 面板局部坐标中的边界矩形。
    ///   - closeButtonFrame: 关闭按钮的面板局部矩形。
    ///   - alpha: 指针下方图片内容的不透明度，范围通常为 `0...1`。
    ///   - alphaThreshold: 低于或等于该值时视为透明内容。
    /// - Returns: 对应的面板交互类型。
    public static func interaction(
        at point: CGPoint,
        in frame: CGRect,
        closeButtonFrame: CGRect,
        alpha: CGFloat,
        alphaThreshold: CGFloat = 0.05
    ) -> PinnedImageInteraction {
        guard frame.width > 0, frame.height > 0,
              point.x >= frame.minX, point.x <= frame.maxX,
              point.y >= frame.minY, point.y <= frame.maxY else { return .passThrough }
        if ellipseContains(point, in: closeButtonFrame) { return .close }
        if let direction = resizeDirection(at: point, in: frame) { return .resize(direction) }
        return alpha.isFinite && alpha > alphaThreshold ? .move : .passThrough
    }

    /// 按拖动方向计算等比缩放后的面板 frame。
    ///
    /// 边缘拖动只使用法线方向位移；角落拖动将指针位移投影到保持原始长宽比的方向。
    /// 每个方向都固定对边中点或对角，最小尺寸也按相同比例收敛。
    ///
    /// - Parameters:
    ///   - frame: 鼠标按下时的起始 frame。
    ///   - direction: 当前拖动的边缘或角落。
    ///   - translation: 从鼠标按下点累计的 AppKit 坐标位移。
    ///   - minimumSize: 允许的最小宽高。
    /// - Returns: 保持起始长宽比并固定锚点的 frame。
    public static func resizedFrame(
        from frame: CGRect,
        direction: PinnedImageResizeDirection,
        translation: CGPoint,
        minimumSize: CGSize
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0,
              frame.width.isFinite, frame.height.isFinite,
              frame.minX.isFinite, frame.minY.isFinite,
              translation.x.isFinite, translation.y.isFinite,
              minimumSize.width.isFinite, minimumSize.height.isFinite else { return frame }

        let aspectRatio = frame.width / frame.height
        let movement = direction.expansionVector
        let widthDelta: CGFloat
        switch direction {
        case .left, .right:
            widthDelta = translation.x * movement.x
        case .top, .bottom:
            widthDelta = translation.y * movement.y * aspectRatio
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            widthDelta = (translation.x * movement.x + translation.y * movement.y / aspectRatio)
                / (1 + 1 / (aspectRatio * aspectRatio))
        }

        let minimumWidth = max(max(0, minimumSize.width), max(0, minimumSize.height) * aspectRatio)
        let effectiveMinimumWidth = min(minimumWidth, frame.width)
        let width = max(effectiveMinimumWidth, frame.width + widthDelta)
        let height = width / aspectRatio
        let anchor = direction.fixedAnchor
        let anchorX = frame.minX + frame.width * anchor.x
        let anchorY = frame.minY + frame.height * anchor.y
        return CGRect(
            x: anchorX - width * anchor.x,
            y: anchorY - height * anchor.y,
            width: width,
            height: height
        )
    }

    /// 根据图片像素宽与选区点宽计算真实缩放倍率。
    ///
    /// - Parameters:
    ///   - imagePixelWidth: 裁剪后图片的像素宽度。
    ///   - pointWidth: 选区在 AppKit 点坐标中的宽度。
    /// - Returns: 缩放倍率；宽度无效时返回 `1`。
    public static func displayScale(imagePixelWidth: CGFloat, pointWidth: CGFloat) -> CGFloat {
        guard imagePixelWidth > 0, pointWidth > 0 else { return 1 }
        return imagePixelWidth / pointWidth
    }

    /// 计算第 `index` 张置顶图相对首张的级联偏移。
    ///
    /// - Parameter index: 从 0 开始的置顶序号。
    /// - Returns: AppKit 点坐标中的偏移量，向右下方向递增。
    public static func cascadeOffset(forIndex index: Int) -> CGPoint {
        let step = CGFloat(max(0, index)) * cascadeStep
        return CGPoint(x: step, y: -step)
    }

    /// 将 frame 收敛到屏幕可见区域内。
    ///
    /// 超出尺寸上限时按比例缩小，保留左下锚点，再以最小平移保证完整可见；不强制居中。
    ///
    /// - Parameters:
    ///   - frame: 期望的 frame（AppKit 点坐标）。
    ///   - screenFrame: 目标屏幕的可见 frame（AppKit 点坐标）。
    /// - Returns: 适配后的 frame。
    public static func fitToScreen(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0,
               frame.width > 0, frame.height > 0 else { return frame }

        let maxWidth = screenFrame.width * 0.9
        let maxHeight = screenFrame.height * 0.9
        let ratio = min(1, min(maxWidth / frame.width, maxHeight / frame.height))
        let size = CGSize(width: frame.width * ratio, height: frame.height * ratio)
        return clampFrameToVisibleBounds(CGRect(origin: frame.origin, size: size), screenFrame: screenFrame)
    }

    /// 只平移 frame，使其完整落入给定可见边界，不改变尺寸。
    ///
    /// 若 frame 大于边界，原点贴到边界左下角并保留原尺寸。
    ///
    /// - Parameters:
    ///   - frame: 期望的 frame（AppKit 点坐标）。
    ///   - screenFrame: 目标屏幕的可见 frame（AppKit 点坐标）。
    /// - Returns: 仅平移后的 frame；任一输入尺寸无效时返回原 frame。
    public static func clampFrameToVisibleBounds(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0,
              screenFrame.width > 0, screenFrame.height > 0 else { return frame }
        return clamped(frame, to: screenFrame)
    }

    /// 将缩放倍率限制到允许区间。
    ///
    /// - Parameter scale: 期望的缩放倍率。
    /// - Returns: 限制后的缩放倍率。
    public static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumScale), maximumScale)
    }

    /// 将不透明度限制到允许区间。
    ///
    /// - Parameter opacity: 期望的不透明度。
    /// - Returns: 限制后的不透明度。
    public static func clampedOpacity(_ opacity: CGFloat) -> CGFloat {
        min(max(opacity, minimumOpacity), maximumOpacity)
    }

    /// 由面板 frame 宽度反推当前缩放倍率。
    ///
    /// 这是缩放的**单一真源**：面板 frame 恒与图片保持同一长宽比
    /// （`fitToScreen` / 恢复原始尺寸 / 拖拽缩放 / 滚轮缩放均同比例变换），
    /// 因此仅用宽度即可还原倍率，不需要任何可变状态。
    /// 不依赖 `backingScaleFactor`——多显示器混合缩放时各屏倍率不同。
    ///
    /// - Parameters:
    ///   - frameWidth: 面板 frame 的当前宽度（AppKit 点）。
    ///   - imagePixelWidth: 图片的像素宽度。
    ///   - displayScale: 图片像素宽与原始选区点宽的比值。
    /// - Returns: 当前缩放倍率；任一输入无效时返回 `1`。
    public static func scale(
        frameWidth: CGFloat,
        imagePixelWidth: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        guard frameWidth > 0, imagePixelWidth > 0, displayScale > 0 else { return 1 }
        return frameWidth / (imagePixelWidth / displayScale)
    }

    /// 将面板 frame 收敛到缩放允许区间内。
    ///
    /// 拖拽缩放手柄允许的最小宽度可能对应到低于 `minimumScale` 的倍率，
    /// 此时把 frame 按比例拉回区间边界，保证工具条读数与实际画面始终一致。
    ///
    /// - Parameters:
    ///   - frame: 期望的面板 frame（AppKit 点坐标）。
    ///   - imagePixelWidth: 图片的像素宽度。
    ///   - displayScale: 图片像素宽与原始选区点宽的比值。
    ///   - anchor: frame 内保持不动的归一化锚点，坐标会钳制到 `0...1`。
    /// - Returns: 收敛后的 frame；原 frame 已在区间内时原样返回。
    public static func clampFrameToScaleRange(
        _ frame: CGRect,
        imagePixelWidth: CGFloat,
        displayScale: CGFloat,
        anchor: CGPoint = .zero
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let current = scale(
            frameWidth: frame.width,
            imagePixelWidth: imagePixelWidth,
            displayScale: displayScale
        )
        let limited = clampedScale(current)
        guard limited != current else { return frame }
        let ratio = limited / current
        let normalizedAnchor = CGPoint(
            x: min(max(anchor.x, 0), 1),
            y: min(max(anchor.y, 0), 1)
        )
        let anchorX = frame.minX + frame.width * normalizedAnchor.x
        let anchorY = frame.minY + frame.height * normalizedAnchor.y
        let width = frame.width * ratio
        let height = frame.height * ratio
        return CGRect(
            x: anchorX - width * normalizedAnchor.x,
            y: anchorY - height * normalizedAnchor.y,
            width: width,
            height: height
        )
    }

    /// 计算置顶面板右上角圆形关闭按钮的 frame。
    ///
    /// 面板较小时按短边比例缩小按钮，避免关闭区域挤占中心移动区域。
    ///
    /// - Parameter frame: 置顶面板的局部边界矩形。
    /// - Returns: 关闭按钮的局部矩形；输入尺寸无效或非有限时返回零矩形。
    public static func closeButtonFrame(in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0,
              frame.width.isFinite, frame.height.isFinite,
              frame.minX.isFinite, frame.minY.isFinite,
              frame.maxX.isFinite, frame.maxY.isFinite else { return .zero }
        let size = min(20, min(frame.width, frame.height) * 0.4)
        let inset = min(6, size * 0.3)
        return CGRect(
            x: frame.maxX - size - inset,
            y: frame.maxY - size - inset,
            width: size,
            height: size
        )
    }

    /// 将缩放倍率映射到 `0...1` 的对数滑杆位置。
    ///
    /// 缩放区间跨越 `maximumScale / minimumScale`（默认 80 倍），线性映射会让
    /// `0...1` 倍只占极小行程而不可用，故改用对数映射。
    ///
    /// - Parameter scale: 期望的缩放倍率（内部先经 `clampedScale` 限制）。
    /// - Returns: `0...1` 的滑杆位置；等于 `minimumScale` 时为 `0`，等于 `maximumScale` 时为 `1`。
    public static func logScalePosition(forScale scale: CGFloat) -> CGFloat {
        let lower = log(minimumScale)
        let upper = log(maximumScale)
        guard upper > lower else { return 0 }
        return (log(clampedScale(scale)) - lower) / (upper - lower)
    }

    /// 将对数滑杆位置反解为缩放倍率。
    ///
    /// 与 `logScalePosition(forScale:)` 互为逆运算。
    ///
    /// - Parameter position: `0...1` 的滑杆位置（内部先限制到 `0...1`）。
    /// - Returns: 对应的缩放倍率，已限制在 `minimumScale...maximumScale`。
    public static func logScaleValue(atPosition position: CGFloat) -> CGFloat {
        let clamped = min(max(position, 0), 1)
        // `exp(log(x))` 存在浮点误差（如 exp(log(8)) = 8.000000000000002），
        // 端点直接短路以保证滑杆两端精确落在允许边界上。
        if clamped <= 0 { return minimumScale }
        if clamped >= 1 { return maximumScale }
        let lower = log(minimumScale)
        let upper = log(maximumScale)
        return clampedScale(exp(lower + (upper - lower) * clamped))
    }

    /// 按可用宽度选择工具条档位。
    ///
    /// - Parameter availableWidth: 工具条可占用的宽度（通常是屏幕可见宽度减去两侧间距）。
    /// - Returns: 放得下 `regular` 最小宽度时返回 `.regular`，否则返回 `.compact`。
    public static func toolbarLayout(availableWidth: CGFloat) -> PinnedToolbarLayout {
        guard availableWidth.isFinite, availableWidth > 0 else { return .compact }
        return availableWidth >= PinnedToolbarLayout.regular.minimumWidth ? .regular : .compact
    }

    /// 计算滑杆在给定可用宽度下的实际宽度。
    ///
    /// 两档布局的差异只在固定件与滑杆区间；这里让滑杆吸收全部剩余宽度并夹在档位区间内，
    /// 使同一档位内工具条宽度随可用宽度连续变化，而不是固定成一个值。
    ///
    /// - Parameters:
    ///   - layout: 布局档位。
    ///   - availableWidth: 工具条可占用的宽度。
    /// - Returns: 单根滑杆的宽度，落在 `layout.sliderRange` 内。
    public static func toolbarSliderWidth(
        layout: PinnedToolbarLayout,
        availableWidth: CGFloat
    ) -> CGFloat {
        guard availableWidth.isFinite else { return layout.sliderRange.lowerBound }
        let slack = (availableWidth - layout.fixedWidth) / 2
        return min(max(slack, layout.sliderRange.lowerBound), layout.sliderRange.upperBound)
    }

    /// 计算工具条总宽度（固定件 + 两根滑杆）。
    ///
    /// - Parameters:
    ///   - layout: 布局档位。
    ///   - availableWidth: 工具条可占用的宽度。
    /// - Returns: 工具条的目标宽度。
    public static func toolbarWidth(
        layout: PinnedToolbarLayout,
        availableWidth: CGFloat
    ) -> CGFloat {
        layout.fixedWidth + 2 * toolbarSliderWidth(layout: layout, availableWidth: availableWidth)
    }

    /// 计算悬浮工具条在 AppKit 全局点坐标中的 frame。
    ///
    /// 竖直候选顺序为**面板下外侧 → 面板上外侧 → 面板底部内侧**：默认置于面板底部外侧，
    /// 面板贴近屏幕底部（下方放不下）时翻到面板上侧，上下都放不下时才回退到面板底部内侧；
    /// 水平方向面板中心对齐，最后对屏幕可见区域做钳制，保证任何摆放都不溢出屏幕。
    ///
    /// - Parameters:
    ///   - panelFrame: 面板的全局 frame（AppKit 点坐标）。
    ///   - toolbarSize: 工具条尺寸（AppKit 点坐标）。
    ///   - screenFrame: 目标屏幕的可见 frame（AppKit 点坐标）。
    /// - Returns: 工具条的全局 frame；尺寸无效时返回 `.zero`。
    public static func toolbarPlacement(
        panelFrame: CGRect,
        toolbarSize: CGSize,
        screenFrame: CGRect
    ) -> CGRect {
        guard toolbarSize.width > 0, toolbarSize.height > 0 else { return .zero }
        guard panelFrame.width > 0, panelFrame.height > 0 else {
            return CGRect(origin: panelFrame.origin, size: toolbarSize)
        }

        let centeredX = panelFrame.midX - toolbarSize.width / 2
        let maximumX = max(screenFrame.minX, screenFrame.maxX - toolbarSize.width)
        let originX = min(max(centeredX, screenFrame.minX), maximumX)
        let size = CGSize(width: toolbarSize.width, height: toolbarSize.height)

        // 只有**完整**放得下才算数：放不下的候选不允许靠钳制硬挤到屏幕边缘，
        // 否则面板几乎占满屏高时工具条会被推到屏幕顶端，远离光标且仍遮住画面。
        let belowPanel = panelFrame.minY - toolbarSpacing - toolbarSize.height
        let abovePanel = panelFrame.maxY + toolbarSpacing
        for candidateY in [belowPanel, abovePanel] where screenFrame.containsVerticalSpan(of: size, atY: candidateY) {
            return CGRect(origin: CGPoint(x: originX, y: candidateY), size: size)
        }

        // 上下外侧都放不下（面板几乎占满屏高）→ 回退到面板底部内侧，覆盖最少且贴近光标。
        let insidePanel = panelFrame.minY + toolbarSpacing
        let maximumY = max(screenFrame.minY, screenFrame.maxY - toolbarSize.height)
        let fallbackY = min(max(insidePanel, screenFrame.minY), maximumY)
        return CGRect(origin: CGPoint(x: originX, y: fallbackY), size: size)
    }

    /// 将工具条尺寸夹到档位允许的宽度区间内，并保证不超出屏幕可见宽度。
    ///
    /// 极端窄屏下 `compact` 的最小宽度仍可能大于可用宽度，此时按可用宽度收窄，
    /// 宁可让内容略微压缩也不让窗口溢出屏幕。
    ///
    /// - Parameters:
    ///   - layout: 布局档位。
    ///   - availableWidth: 工具条可占用的宽度。
    /// - Returns: 工具条的目标宽度。
    public static func clampedToolbarWidth(
        layout: PinnedToolbarLayout,
        availableWidth: CGFloat
    ) -> CGFloat {
        let width = toolbarWidth(layout: layout, availableWidth: availableWidth)
        guard availableWidth.isFinite, availableWidth > 0 else { return width }
        return min(width, availableWidth)
    }

    /// 将工具条尺寸向上取整到整数点。
    ///
    /// 滑杆宽度常出现半点（如 109.5），窗口与滑杆落位后可能出现亚像素错位；
    /// 统一取整到「不小于需求」的整数值，既消除亚像素，又不会让内容超出窗口。
    ///
    /// - Parameter size: 测量或计算出的尺寸。
    /// - Returns: 宽高均为整数的尺寸；输入无效时原样返回。
    public static func integralToolbarSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            return size
        }
        return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    /// 将矩形钳制到给定边界内。
    private static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return rect }
        let maxX = max(bounds.minX, bounds.maxX - rect.width)
        let maxY = max(bounds.minY, bounds.maxY - rect.height)
        return CGRect(
            x: min(max(rect.minX, bounds.minX), maxX),
            y: min(max(rect.minY, bounds.minY), maxY),
            width: rect.width,
            height: rect.height
        )
    }

    private static func cornerDirection(
        left: CGFloat,
        right: CGFloat,
        bottom: CGFloat,
        top: CGFloat,
        hitSize: CGSize
    ) -> PinnedImageResizeDirection? {
        if left <= hitSize.width, top <= hitSize.height { return .topLeft }
        if right <= hitSize.width, top <= hitSize.height { return .topRight }
        if left <= hitSize.width, bottom <= hitSize.height { return .bottomLeft }
        if right <= hitSize.width, bottom <= hitSize.height { return .bottomRight }
        return nil
    }

    private static func ellipseContains(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0,
              rect.width.isFinite, rect.height.isFinite,
              rect.minX.isFinite, rect.minY.isFinite else { return false }
        let normalizedX = (point.x - rect.midX) / (rect.width / 2)
        let normalizedY = (point.y - rect.midY) / (rect.height / 2)
        let normalizedDistance = normalizedX * normalizedX + normalizedY * normalizedY
        return normalizedX.isFinite && normalizedY.isFinite && normalizedDistance <= 1
    }
}

extension CGRect {
    /// 判断尺寸为 `size` 的矩形竖直放在 `originY` 处时，是否完整落在当前矩形内。
    ///
    /// 用于工具条竖直候选的可行性判断：放不下就不采用，避免被钳制到屏幕边缘。
    ///
    /// - Parameters:
    ///   - size: 待放置矩形的尺寸。
    ///   - originY: 待放置矩形的下边缘。
    /// - Returns: 完整落在当前矩形内时为 `true`。
    fileprivate func containsVerticalSpan(of size: CGSize, atY originY: CGFloat) -> Bool {
        originY >= minY && originY + size.height <= maxY
    }
}
