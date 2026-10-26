import AppKit
import BarcodeCore
import SharedKit

// MARK: - BarcodeResultPanel

/// 选区条码识别的结果浮层。
///
/// 与动作栏同族：`NSVisualEffectView` + `.hudWindow` + `.withinWindow`。
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

    static let width: CGFloat = 320
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 10
    private static let maximumRows = 5
    private static let contentWidth: CGFloat = width - horizontalInset * 2

    private struct CopyTarget {
        let button: NSButton
        let title: String
        let imagePosition: NSControl.ImagePosition
        let payload: String
    }

    private let stack = NSStackView()
    private var copyTargets: [CopyTarget] = []
    private var copiedResetWorkItem: DispatchWorkItem?
    /// 识别中沿用上一次内容高度，避免面板高度跳动。
    private var retainedHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .withinWindow
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

    /// 复制成功反馈：对应按钮标题短暂换成「已复制」。
    func markCopied(payload: String) {
        guard let target = copyTargets.first(where: { $0.payload == payload }) else { return }
        copiedResetWorkItem?.cancel()
        target.button.title = AppLocalization.string("Copied")
        target.button.imagePosition = .noImage
        let workItem = DispatchWorkItem { [weak self, weak button = target.button] in
            button?.title = target.title
            button?.imagePosition = target.imagePosition
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
        var actions: [NSView] = [
            copyButton(payload: payload.text, title: AppLocalization.string("Copy Content")),
        ]
        if let url = payload.webLink {
            actions.append(
                button(
                    title: AppLocalization.string("Open Link"),
                    symbol: "arrow.up.right.square",
                    emphasis: false
                ) { [weak self] in self?.onOpenLink?(url) }
            )
        }

        let actionRow = NSStackView(views: actions)
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        return [
            header(title: AppLocalization.string("Barcode found"), badge: payload.type.displayName),
            payloadLabel(payload.text, lines: 2),
            actionRow,
        ]
    }

    private func multiResultContent(payloads: [BarcodePayload]) -> [NSView] {
        var views: [NSView] = [
            header(
                title: AppLocalization.string("%d barcodes found", payloads.count),
                badge: nil
            ),
        ]
        for payload in payloads.prefix(Self.maximumRows) {
            views.append(row(for: payload))
        }
        if payloads.count > 1 {
            let joined = payloads.map(\.text).joined(separator: "\n")
            views.append(
                copyButton(
                    payload: joined,
                    title: AppLocalization.string("Copy All"),
                    isCopyAll: true
                )
            )
        }
        return views
    }

    private func row(for payload: BarcodePayload) -> NSView {
        let copy = copyButton(
            payload: payload.text,
            title: AppLocalization.string("Copy Content"),
            compact: true
        )
        let row = NSStackView(views: [
            badge(payload.type.displayName),
            payloadLabel(
                payload.text,
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
            rescanButton(),
        ]
    }

    private func failureContent(message: String) -> [NSView] {
        [
            label(message, font: .systemFont(ofSize: 12), color: .systemRed, lines: 2),
            rescanButton(),
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
        views.append(rescanButton())

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func rescanButton() -> NSButton {
        button(
            title: AppLocalization.string("Scan Again"),
            symbol: "arrow.clockwise",
            emphasis: false
        ) { [weak self] in self?.onRescan?() }
    }

    // MARK: - Controls

    private func copyButton(
        payload: String,
        title: String,
        compact: Bool = false,
        isCopyAll: Bool = false
    ) -> NSButton {
        let control = button(title: title, symbol: "doc.on.doc", emphasis: true) { [weak self] in
            if isCopyAll {
                self?.onCopyAll?()
            } else {
                self?.onCopy?(payload)
            }
        }
        if compact {
            control.title = ""
            control.imagePosition = .imageOnly
            control.toolTip = AppLocalization.string("Copy Content")
            control.setAccessibilityLabel(AppLocalization.string("Copy Content"))
        }
        copyTargets.append(
            CopyTarget(
                button: control,
                title: control.title,
                imagePosition: control.imagePosition,
                payload: payload
            )
        )
        return control
    }

    private func button(
        title: String,
        symbol: String,
        emphasis: Bool,
        action: @escaping () -> Void
    ) -> NSButton {
        let control = ClosureButton(title: title, onPress: action)
        control.bezelStyle = emphasis ? .rounded : .inline
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11, weight: emphasis ? .semibold : .regular)
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        control.imagePosition = .imageLeading
        control.setAccessibilityLabel(title)
        return control
    }

    private func badge(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10, weight: .semibold)
        field.textColor = .labelColor
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        field.layer?.cornerRadius = 4
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        field.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return field
    }

    private func payloadLabel(
        _ text: String,
        lines: Int,
        maxWidth: CGFloat = contentWidth
    ) -> NSTextField {
        let field = label(
            text,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            color: .labelColor,
            lines: lines,
            maxWidth: maxWidth
        )
        field.isSelectable = true
        field.toolTip = text
        return field
    }

    private func label(
        _ text: String,
        font: NSFont,
        color: NSColor,
        lines: Int = 1,
        maxWidth: CGFloat = contentWidth
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = lines > 1 ? .byTruncatingMiddle : .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        return field
    }

    // MARK: - Helpers

    private func removeAllRows() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

// MARK: - ClosureButton

/// 面板里的按钮只做一件事，用闭包比逐个开 selector 更省。
private final class ClosureButton: NSButton {
    private let onPress: () -> Void

    init(title: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func press() {
        onPress()
    }
}
