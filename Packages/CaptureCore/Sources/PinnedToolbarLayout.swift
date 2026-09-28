import CoreGraphics

// MARK: - PinnedToolbarLayout

/// 置顶工具条的布局档位。
///
/// 工具条宽度是自适应的：档位由可用宽度选出，同一档位内两根滑杆再吸收全部剩余宽度
/// （夹在档位的伸缩区间内），因此无论屏幕宽窄，内容都不会超出窗口而被裁切。
/// 纯值类型，不依赖 AppKit，可在 `swift test --package-path Packages/CaptureCore` 下直接验证。
public enum PinnedToolbarLayout: Sendable, CaseIterable {
    /// 常规档：可用宽度充足，保留两个前导图标。
    case regular

    /// 紧凑档：可用宽度不足，省略前导图标并收紧间距与控件尺寸。
    case compact
}

// MARK: - 度量

extension PinnedToolbarLayout {
    /// 前导图标宽度（点）。
    private static let leadingIconWidth: CGFloat = 14

    /// 竖直分隔线宽度（点）。
    private static let separatorWidth: CGFloat = 1

    /// 档位内控件间距（点）。
    public var spacing: CGFloat {
        switch self {
        case .regular: 6
        case .compact: 4
        }
    }

    /// 水平外边距（点）。不小于圆角半径的一半，使控件避开窗口圆角裁切区。
    public var marginHorizontal: CGFloat {
        switch self {
        case .regular: 10
        case .compact: 8
        }
    }

    /// 竖直外边距（点）。不小于圆角半径的一半，使控件避开窗口圆角裁切区。
    public var marginVertical: CGFloat {
        switch self {
        case .regular: 8
        case .compact: 6
        }
    }

    /// 滑杆宽度的伸缩区间（点）。
    ///
    /// 是区间而非固定值：实际宽度由 `PinnedImageGeometry.toolbarSliderWidth` 在区间内夹取，
    /// 这正是「响应式」的落点——同一档位内滑杆随可用宽度连续伸缩。
    public var sliderRange: ClosedRange<CGFloat> {
        switch self {
        case .regular: 52...120
        case .compact: 36...72
        }
    }

    /// 百分比读数宽度（点）。固定值，避免数字变化引起布局抖动。
    public var percentLabelWidth: CGFloat {
        switch self {
        case .regular: 38
        case .compact: 32
        }
    }

    /// 图标按钮宽度（点）。
    ///
    /// 取值不低于 AppKit 图钉按钮的固有宽度（`.small` 约 33、`.mini` 约 27），
    /// 否则按钮会窄于图标本身而被裁切；略宽的部分只是按钮内的留白。
    public var buttonWidth: CGFloat {
        switch self {
        case .regular: 34
        case .compact: 28
        }
    }

    /// 是否显示两根前导图标。
    public var showsLeadingIcons: Bool {
        switch self {
        case .regular: true
        case .compact: false
        }
    }

    /// 固定元素个数：两个图标按钮 + 分隔线 + 读数，再加可选的两根前导图标。
    ///
    /// 两根滑杆是唯一可伸缩的元素，因此不计入固定元素，但**计入间隙数**。
    private var fixedElementCount: Int { showsLeadingIcons ? 8 : 6 }

    /// 固定元素宽度合计（含间隙与水平外边距，不含两根滑杆）。
    ///
    /// 由各控件宽度累加得出，不是手写魔数：
    /// - regular：`14 + 14 + 1 + 38 + 34 + 34 = 135`，间隙 `7 × 6 = 42`，边距 `2 × 10 = 20` → 197
    /// - compact：`1 + 32 + 28 + 28 = 89`，间隙 `5 × 4 = 20`，边距 `2 × 8 = 16` → 125
    public var fixedWidth: CGFloat {
        let controls = (showsLeadingIcons ? 2 * Self.leadingIconWidth : 0)
            + Self.separatorWidth
            + percentLabelWidth
            + 2 * buttonWidth
        let gaps = CGFloat(fixedElementCount - 1) * spacing
        return controls + gaps + 2 * marginHorizontal
    }

    /// 最小内容高度（点）：由档位内**最高**的控件决定。
    ///
    /// - `regular`：图标 `.small` 按钮均为 20pt，高于分隔线 18pt，故取 20。
    /// - `compact`：无前导图标，最高的控件是 18pt 分隔线（`.mini` 按钮仅 16pt），故取 18。
    public var contentHeight: CGFloat {
        switch self {
        case .regular: 20
        case .compact: 18
        }
    }

    /// 高度下限（点）= 内容高 + 上下外边距。
    ///
    /// 由 `contentHeight` 推导而非写死：曾因高度与内容脱钩（窗口比内容矮）导致工具条被
    /// `masksToBounds` 裁切，此处把「放得下内容 + 上下边距」固化成不变量。
    public var minimumHeight: CGFloat { contentHeight + 2 * marginVertical }

    /// 最小可用宽度 = 固定件 + 两根滑杆的最小宽度。
    public var minimumWidth: CGFloat { fixedWidth + 2 * sliderRange.lowerBound }

    /// 最大宽度 = 固定件 + 两根滑杆的最大宽度。
    public var maximumWidth: CGFloat { fixedWidth + 2 * sliderRange.upperBound }
}
