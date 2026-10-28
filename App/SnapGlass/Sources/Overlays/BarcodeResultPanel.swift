import AppKit
import BarcodeCore
import SharedKit

// MARK: - BarcodeResultPanel

/// 选区条码识别的结果浮层。
///
/// 与动作栏同族：`NSVisualEffectView` + `.hudWindow` + `.behindWindow`。
/// 它是 `AreaTrackingView` 的子视图而不是独立窗口，因此不会被自己的截图
/// 收进去，也不依赖任何 `sharingType` 处理。
///
/// 面板只负责摆放和反馈：payload 的整理、去重、链接判定全部来自
/// `BarcodeCore`，按钮事件通过闭包交给 `AreaTrackingView` 执行。
final class BarcodeResultPanel: NSVisualEffectView {
    var onCopy: ((String) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onRescan: (() -> Void)?
    var onCopyAll: (() -> Void)?
    /// 显式关闭；点卡片外与 `esc` 由选区视图处理。
    var onClose: (() -> Void)?

    static let width: CGFloat = 360
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 10
    static let contentWidth: CGFloat = width - horizontalInset * 2
    /// 正文最多三行：看得清长链接，又不至于把浮层撑成一块板。
    static let payloadLines = 3
    /// 多结果最多平铺五行，其余折叠成「还有 N 条」。
    private static let maximumRows = 5

    struct CopyTarget {
        let button: NSButton
        let title: String
        let image: NSImage?
        let imagePosition: NSControl.ImagePosition
        let payload: String
    }

    private let stack = NSStackView()
    private(set) var copyTargets: [CopyTarget] = []
    private var copiedResetWorkItem: DispatchWorkItem?
    /// 单条结果的正文字段：兜底点击需要它接管选中。
    private(set) weak var primaryPayloadField: NSTextField?
    /// 识别中沿用上一次内容高度，避免面板高度跳动。
    private var retainedHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        // 宿主 `AreaSelectionPanel` 是 clear + 非 opaque：窗内没有可采样的内容，
        // `.withinWindow` 只会退化成一块灰底。改用 `.behindWindow` 采桌面，
        // 与 `PinnedToolbarView` 保持一致。
        blendingMode = .behindWindow
        // HUD 恒定深色：上面的语义文字色据此解析，浅色系统与「降低透明度」下都保持浅字。
        appearance = NSAppearance(named: .darkAqua)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(AppLocalization.string("Barcode Results"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Interaction

    /// 卡片吞掉落在自己身上的点击。
    ///
    /// 选区视图把「不在动作栏上的点击」当作点空白并收起浮层；如果卡片不拦，
    /// 一次正文点击就会连带关掉结果。拦在这里比让事件继续冒泡更可靠。
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        if let button = allButtons.first(where: { $0.convert($0.bounds, to: self).contains(point) }) {
            return button
        }
        return super.hitTest(point) ?? self
    }

    /// 兜底点击分发。
    ///
    /// 浮层是 `.screenSaver` 级别的非激活面板，首次点击偶尔会绕过控件直接落到
    /// 选区视图。此时按坐标把点击补派一次，避免「按钮/文本点不动」。
    /// 与 `CaptureActionBarView.performAction(at:)` 同一套做法。
    ///
    /// - Returns: 点是否落在卡片内（落在卡内一律不算「点空白」）。
    @discardableResult
    func handleClick(at point: CGPoint) -> Bool {
        guard !isHidden, bounds.contains(point) else { return false }
        if let button = allButtons.first(where: { $0.convert($0.bounds, to: self).contains(point) }) {
            button.performClick(nil)
            return true
        }
        if let field = primaryPayloadField,
           field.convert(field.bounds, to: self).contains(point) {
            window?.makeFirstResponder(field)
            field.selectText(nil)
            return true
        }
        return true
    }

    // MARK: - Sizing

    /// 面板当前需要的尺寸；高度按内容计算，宽度固定。
    var preferredSize: CGSize {
        stack.layoutSubtreeIfNeeded()
        let contentHeight = stack.fittingSize.height + Self.verticalInset * 2
        return CGSize(width: Self.width, height: max(44, retainedHeight, contentHeight))
    }

    // MARK: - Content

    /// 用新的扫描状态重建面板内容。
    func update(state: ScanState) {
        copiedResetWorkItem?.cancel()
        copyTargets.removeAll()
        primaryPayloadField = nil
        removeAllRows()

        for view in content(for: state) {
            stack.addArrangedSubview(view)
        }

        switch state {
        case .idle:
            retainedHeight = 0
        case .scanning:
            // 识别中沿用上一轮高度，面板不跳动。
            break
        case .results, .empty, .failed:
            retainedHeight = 0
            retainedHeight = preferredSize.height
        }
    }

    /// 复制成功反馈：按钮短暂换成「已复制」，图标按钮保持宽度不变。
    func markCopied(payload: String) {
        guard let target = copyTargets.first(where: { $0.payload == payload }) else { return }
        copiedResetWorkItem?.cancel()

        if target.imagePosition == .imageOnly {
            target.button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            target.button.toolTip = AppLocalization.string("Copied")
            target.button.setAccessibilityLabel(AppLocalization.string("Copied"))
        } else {
            target.button.title = AppLocalization.string("Copied")
            target.button.imagePosition = .noImage
        }

        let workItem = DispatchWorkItem { [weak self, weak button = target.button] in
            guard let button else { return }
            if target.imagePosition == .imageOnly {
                button.image = target.image
                button.toolTip = target.title
                button.setAccessibilityLabel(target.title)
            } else {
                button.title = target.title
                button.imagePosition = target.imagePosition
            }
            self?.copiedResetWorkItem = nil
        }
        copiedResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func content(for state: ScanState) -> [NSView] {
        switch state {
        case .idle:
            return []
        case .scanning:
            return [scanningRow()]
        case .results(let results):
            let payloads = BarcodePayloadFormatter.payloads(from: results)
            guard let first = payloads.first else { return emptyContent() }
            return payloads.count == 1 ? singleResultContent(payload: first) : multiResultContent(payloads: payloads)
        case .empty:
            return emptyContent()
        case .failed(let message):
            return failureContent(message: message)
        }
    }

    // MARK: - Sections

    private func scanningRow() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let row = NSStackView(views: [
            spinner,
            label(
                AppLocalization.string("Scanning…"),
                font: .systemFont(ofSize: 12),
                color: .secondaryLabelColor
            ),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func singleResultContent(payload: BarcodePayload) -> [NSView] {
        let field = payloadField(payload, lines: Self.payloadLines)
        primaryPayloadField = field

        var actions: [NSView] = []
        if let url = payload.webLink {
            actions.append(
                copyButton(
                    payload: payload.text,
                    title: AppLocalization.string("Copy Content"),
                    role: .secondary
                )
            )
            actions.append(
                button(
                    title: AppLocalization.string("Open Link"),
                    symbol: "arrow.up.right.square",
                    role: .primary
                ) { [weak self] in self?.onOpenLink?(url) }
            )
        } else {
            actions.append(
                copyButton(
                    payload: payload.text,
                    title: AppLocalization.string("Copy Content"),
                    role: .primary
                )
            )
        }

        let actionRow = NSStackView(views: actions)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        return [
            header(title: AppLocalization.string("Barcode found"), badge: payload.type.displayName),
            field,
            actionRow,
            hintLabel(hasLink: payload.webLink != nil),
        ]
    }

    private func multiResultContent(payloads: [BarcodePayload]) -> [NSView] {
        var views: [NSView] = [
            header(
                title: AppLocalization.string("%lld barcodes found", payloads.count),
                badge: nil
            ),
        ]
        for payload in payloads.prefix(Self.maximumRows) {
            views.append(row(for: payload))
        }
        let overflow = payloads.count - Self.maximumRows
        if overflow > 0 {
            views.append(
                label(
                    AppLocalization.string("%d more", overflow),
                    font: .systemFont(ofSize: 11),
                    color: .tertiaryLabelColor
                )
            )
        }
        if payloads.count > 1 {
            let joined = payloads.map(\.text).joined(separator: "\n")
            let copyAll = button(
                title: AppLocalization.string("Copy All"),
                symbol: "doc.on.doc",
                role: .secondary
            ) { [weak self] in self?.onCopyAll?() }
            registerCopyTarget(joined, button: copyAll)
            views.append(copyAll)
        }
        return views
    }

    private func row(for payload: BarcodePayload) -> NSView {
        let copy = copyButton(
            payload: payload.text,
            title: AppLocalization.string("Copy Content"),
            role: .icon
        )
        let row = NSStackView(views: [
            badge(payload.type.displayName),
            payloadField(
                payload,
                lines: 1,
                maxWidth: Self.contentWidth - 44 - 32 - 16
            ),
            copy,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func emptyContent() -> [NSView] {
        [
            label(
                AppLocalization.string("No barcode in selection"),
                font: .systemFont(ofSize: 12),
                color: .secondaryLabelColor,
                lines: 2
            ),
            rescanButton(role: .secondary),
        ]
    }

    private func failureContent(message: String) -> [NSView] {
        [
            label(message, font: .systemFont(ofSize: 12), color: .systemRed, lines: 2),
            rescanButton(role: .secondary),
        ]
    }

    private func header(title: String, badge badgeText: String?) -> NSView {
        var views: [NSView] = []
        var reserved: CGFloat = 0
        if let badgeText {
            views.append(badge(badgeText))
            reserved += 44
        }
        views.append(
            label(
                title,
                font: .systemFont(ofSize: 12, weight: .semibold),
                color: .labelColor,
                maxWidth: Self.contentWidth - reserved - 96
            )
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        views.append(spacer)
        views.append(rescanButton(role: .icon))
        views.append(closeButton())

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func rescanButton(role: ButtonRole) -> NSButton {
        button(
            title: AppLocalization.string("Scan Again"),
            symbol: "arrow.clockwise",
            role: role
        ) { [weak self] in self?.onRescan?() }
    }

    private func closeButton() -> NSButton {
        button(
            title: AppLocalization.string("Close"),
            symbol: "xmark",
            role: .icon
        ) { [weak self] in self?.onClose?() }
    }

    private func hintLabel(hasLink: Bool) -> NSTextField {
        label(
            AppLocalization.string(hasLink ? "Barcode Hint with Link" : "Barcode Hint"),
            font: .systemFont(ofSize: 10),
            color: .tertiaryLabelColor
        )
    }

    // MARK: - Helpers

    private func copyButton(
        payload: String,
        title: String,
        role: ButtonRole
    ) -> NSButton {
        let control = button(title: title, symbol: "doc.on.doc", role: role) { [weak self] in
            self?.onCopy?(payload)
        }
        registerCopyTarget(payload, button: control)
        return control
    }

    private func registerCopyTarget(_ payload: String, button: NSButton) {
        copyTargets.append(
            CopyTarget(
                button: button,
                title: button.toolTip ?? button.title,
                image: button.image,
                imagePosition: button.imagePosition,
                payload: payload
            )
        )
    }

    private var allButtons: [NSButton] {
        var buttons: [NSButton] = []
        func collect(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            for subview in view.subviews { collect(subview) }
        }
        collect(self)
        return buttons
    }

    private func removeAllRows() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
