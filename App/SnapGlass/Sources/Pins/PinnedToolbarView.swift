import AppKit
import CaptureCore

// MARK: - PinnedToolbarView

/// 置顶面板的悬浮编辑工具条。
///
/// 回调式 API：自身不持有窗口，也不直接改动面板，全部通过回调上抛，
/// 便于由 `PinnedImageView` 统一协调。
///
/// 使用 AppKit 而非 SwiftUI，与现有悬浮组件（`CaptureActionBarView`）保持一致。
/// 尺寸由档位（`PinnedToolbarLayout`）决定：两个按钮只显示图标以压缩宽度，
/// 两根滑杆在档位区间内吸收全部剩余宽度，因此内容恒与窗口等宽、不会被裁切。
@MainActor
final class PinnedToolbarView: NSVisualEffectView {
    /// 不透明度滑杆拖动中（用于抑制工具条自动隐藏）。
    var onInteractionChange: ((Bool) -> Void)?

    /// 鼠标进入/离开工具条，用于取消或重启延迟隐藏。
    var onPointerEnter: (() -> Void)?
    var onPointerExit: (() -> Void)?

    /// 不透明度变化（`minimumOpacity...maximumOpacity`）。
    var onOpacityChange: ((CGFloat) -> Void)?

    /// 缩放倍率变化（`minimumScale...maximumScale`）。
    var onScaleChange: ((CGFloat) -> Void)?

    /// 恢复到原始尺寸（1:1）。
    var onResetSize: (() -> Void)?

    /// 适应屏幕。
    var onFitToScreen: (() -> Void)?

    /// 窗口圆角半径。外边距不小于其一半，使控件避开圆角裁切区。
    static let cornerRadius: CGFloat = 8

    private let opacitySlider = SliderInteractionReportingSlider()
    private let scaleSlider = SliderInteractionReportingSlider()
    private let scaleLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton()
    private let fitButton = NSButton()
    private let opacityIcon = NSImageView()
    private let scaleIcon = NSImageView()
    private let separator = NSView()
    private let stack = NSStackView()

    private var trackingAreaReference: NSTrackingArea?

    /// 当前档位。
    private(set) var layout: PinnedToolbarLayout = .regular

    private var horizontalMarginConstraints: [NSLayoutConstraint] = []
    private var verticalMarginConstraints: [NSLayoutConstraint] = []
    private var sliderWidthConstraints: [NSLayoutConstraint] = []
    private var buttonWidthConstraints: [NSLayoutConstraint] = []
    private var labelWidthConstraint: NSLayoutConstraint?

    /// 百分比格式化器。滑杆拖动期间每次变化都会使用，避免重复构造。
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        configureControls()
        wireInteractionReporting()
        buildStack()
        apply(layout: .regular)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppLocalization.string("Pinned Image Toolbar"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExit?()
    }

    // MARK: - 档位应用

    /// 应用布局档位：图标显隐、控件尺寸、间距与外边距全部随之切换。
    ///
    /// 滑杆宽度只是**上下限**而非定值，窗口宽度由 `PinnedImageGeometry` 按可用宽度算出，
    /// 两根滑杆在同一档位内吸收全部剩余宽度，从而真正随屏幕宽窄伸缩。
    ///
    /// - Parameter layout: 目标档位。
    func apply(layout: PinnedToolbarLayout) {
        self.layout = layout

        opacityIcon.isHidden = !layout.showsLeadingIcons
        scaleIcon.isHidden = !layout.showsLeadingIcons

        NSLayoutConstraint.deactivate(sliderWidthConstraints)
        let minimumOpacity = opacitySlider.widthAnchor.constraint(
            greaterThanOrEqualToConstant: layout.sliderRange.lowerBound
        )
        let minimumScale = scaleSlider.widthAnchor.constraint(
            greaterThanOrEqualToConstant: layout.sliderRange.lowerBound
        )
        // 下限用 750 而非 required：极端窄屏时窗口按可用宽度收窄，允许静默让步，
        // 避免「无法同时满足约束」的冲突日志污染控制台。
        minimumOpacity.priority = .defaultHigh
        minimumScale.priority = .defaultHigh
        let maximumOpacity = opacitySlider.widthAnchor.constraint(
            lessThanOrEqualToConstant: layout.sliderRange.upperBound
        )
        let maximumScale = scaleSlider.widthAnchor.constraint(
            lessThanOrEqualToConstant: layout.sliderRange.upperBound
        )
        sliderWidthConstraints = [minimumOpacity, minimumScale, maximumOpacity, maximumScale]
        NSLayoutConstraint.activate(sliderWidthConstraints)

        NSLayoutConstraint.deactivate(buttonWidthConstraints)
        buttonWidthConstraints = [resetButton, fitButton].map {
            $0.widthAnchor.constraint(equalToConstant: layout.buttonWidth)
        }
        NSLayoutConstraint.activate(buttonWidthConstraints)

        labelWidthConstraint?.isActive = false
        let labelConstraint = scaleLabel.widthAnchor.constraint(equalToConstant: layout.percentLabelWidth)
        labelConstraint.isActive = true
        labelWidthConstraint = labelConstraint

        let controlSize: NSControl.ControlSize = layout == .regular ? .small : .mini
        for button in [resetButton, fitButton] {
            button.controlSize = controlSize
        }

        stack.spacing = layout.spacing

        // 外边距必须带符号：trailing / bottom 与锚点同向，常量取负，
        // 否则约束变为负高度、`fittingSize` 会吃掉上下边距，工具条被裁切。
        if let leading = horizontalMarginConstraints.first {
            leading.constant = layout.marginHorizontal
        }
        if let trailing = horizontalMarginConstraints.last {
            trailing.constant = -layout.marginHorizontal
        }
        if let top = verticalMarginConstraints.first {
            top.constant = layout.marginVertical
        }
        if let bottom = verticalMarginConstraints.last {
            bottom.constant = -layout.marginVertical
        }

        // `controlSize` 改变固有尺寸后必须重新布局，否则外部读到的 `fittingSize` 是陈旧值。
        needsLayout = true
    }

    // MARK: - 外部同步

    /// 同步不透明度读数（滚轮 / `⌥`+滚轮触发）。
    func updateOpacity(_ opacity: CGFloat) {
        opacitySlider.doubleValue = Double(PinnedImageGeometry.clampedOpacity(opacity))
    }

    /// 同步缩放读数（滚轮 / 捏合 / 适应屏幕 / 1:1 触发）。
    func updateScale(_ scale: CGFloat) {
        let clamped = PinnedImageGeometry.clampedScale(scale)
        scaleSlider.doubleValue = Double(PinnedImageGeometry.logScalePosition(forScale: clamped))
        scaleLabel.stringValue = Self.percentText(for: clamped)
    }

    private static func percentText(for scale: CGFloat) -> String {
        percentFormatter.string(from: NSNumber(value: Double(scale)))
            ?? "\(Int((scale * 100).rounded()))%"
    }

    // MARK: - 构建

    private func buildStack() {
        opacityIcon.image = Self.symbolImage("circle.lefthalf.filled")
        scaleIcon.image = Self.symbolImage("arrow.up.left.and.arrow.down.right")
        for icon in [opacityIcon, scaleIcon] {
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: Self.leadingIconWidth),
                icon.heightAnchor.constraint(equalToConstant: Self.leadingIconWidth),
            ])
        }

        // 竖直分隔线：不用 `NSBox(.separator)`，它自带固有尺寸，再叠加显式宽高约束易冲突。
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: Self.separatorWidth),
            separator.heightAnchor.constraint(equalToConstant: 18),
        ])

        for view in [
            opacityIcon,
            opacitySlider,
            separator,
            scaleIcon,
            scaleSlider,
            scaleLabel,
            resetButton,
            fitButton,
        ] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // 先以 0 创建、再由 `apply(layout:)` 按档位写入带符号的常量
        // （trailing / bottom 与锚点同向，必须取负）。初始化末尾即会调用 `apply`。
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        let top = stack.topAnchor.constraint(equalTo: topAnchor)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        horizontalMarginConstraints = [leading, trailing]
        verticalMarginConstraints = [top, bottom]
        NSLayoutConstraint.activate([leading, trailing, top, bottom])

        // `.fill` 分配不会保证两根滑杆等宽（可能把余量集中给第一根），显式约束等宽。
        opacitySlider.widthAnchor.constraint(equalTo: scaleSlider.widthAnchor).isActive = true
    }

    private func configureControls() {
        opacitySlider.minValue = Double(PinnedImageGeometry.minimumOpacity)
        opacitySlider.maxValue = Double(PinnedImageGeometry.maximumOpacity)
        opacitySlider.doubleValue = 1
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.setAccessibilityLabel(AppLocalization.string("Opacity"))

        scaleSlider.minValue = 0
        scaleSlider.maxValue = 1
        scaleSlider.doubleValue = Double(PinnedImageGeometry.logScalePosition(forScale: 1))
        scaleSlider.isContinuous = true
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged)
        scaleSlider.setAccessibilityLabel(AppLocalization.string("Zoom"))

        scaleLabel.alignment = .right
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        scaleLabel.textColor = .secondaryLabelColor
        scaleLabel.setAccessibilityLabel(AppLocalization.string("Zoom"))

        // 让滑杆吸收全部剩余宽度，固定件保持固有尺寸。
        for slider in [opacitySlider, scaleSlider] {
            slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
            slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        configure(
            resetButton,
            symbol: "1.square",
            label: AppLocalization.string("Scale"),
            action: #selector(resetSize)
        )
        configure(
            fitButton,
            symbol: "arrow.down.right.and.arrow.up.left",
            label: AppLocalization.string("Fit to Screen"),
            action: #selector(fitToScreen)
        )
    }

    /// 配置图标按钮：只显示图标（不显示标题），语义交给 toolTip 与无障碍标签。
    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.title = ""
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = Self.symbolImage(symbol)
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    private static func symbolImage(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// 前导图标宽度（点）。与 `PinnedToolbarLayout` 的固定件推导保持一致。
    private static let leadingIconWidth: CGFloat = 14

    /// 竖直分隔线宽度（点）。
    private static let separatorWidth: CGFloat = 1

    // MARK: - 动作

    @objc private func opacityChanged() {
        onOpacityChange?(CGFloat(opacitySlider.doubleValue))
    }

    @objc private func scaleChanged() {
        let scale = PinnedImageGeometry.logScaleValue(atPosition: CGFloat(scaleSlider.doubleValue))
        scaleLabel.stringValue = Self.percentText(for: scale)
        onScaleChange?(scale)
    }

    @objc private func resetSize() {
        onResetSize?()
    }

    @objc private func fitToScreen() {
        onFitToScreen?()
    }

    /// 绑定两个滑杆的拖拽起止，用于在拖动期间抑制工具条自动隐藏。
    private func wireInteractionReporting() {
        for slider in [opacitySlider, scaleSlider] {
            slider.onDragStateChange = { [weak self] isDragging in
                self?.onInteractionChange?(isDragging)
            }
        }
    }
}

// MARK: - SliderInteractionReportingSlider

/// 可上报拖拽起止的 `NSSlider`。
///
/// `NSSlider` 只有连续 action，没有「拖拽结束」回调；而 `super.mouseDown` 会一直
/// 阻塞到鼠标抬起，因此可安全地把整个调用包裹成开始 / 结束两个事件。
private final class SliderInteractionReportingSlider: NSSlider {
    var onDragStateChange: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onDragStateChange?(true)
        super.mouseDown(with: event)
        onDragStateChange?(false)
    }
}
