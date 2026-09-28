import CoreGraphics

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
    /// 超出屏幕时按比例缩小并居中，避免面板初始位置落在屏幕之外。
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
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
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
    /// - Returns: 收敛后的 frame；原 frame 已在区间内时原样返回。
    public static func clampFrameToScaleRange(
        _ frame: CGRect,
        imagePixelWidth: CGFloat,
        displayScale: CGFloat
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
        return CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width * ratio,
            height: frame.height * ratio
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
