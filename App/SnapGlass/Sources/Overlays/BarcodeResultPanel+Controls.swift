import AppKit
import BarcodeCore

// MARK: - 控件构造

/// 面板里按钮的三种层级：主操作、次级操作、图标。
enum ButtonRole {
    case primary
    case secondary
    case icon
}

extension BarcodeResultPanel {
    // MARK: - 按钮

    func button(
        title: String,
        symbol: String,
        role: ButtonRole,
        action: @escaping () -> Void
    ) -> NSButton {
        let control = ClosureButton(title: title, onPress: action)
        control.controlSize = .small
        control.toolTip = title
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        control.setAccessibilityLabel(title)

        switch role {
        case .primary:
            control.bezelStyle = .rounded
            control.bezelColor = .controlAccentColor
            control.contentTintColor = .white
            control.font = .systemFont(ofSize: 11, weight: .semibold)
            control.imagePosition = .imageLeading
        case .secondary:
            control.bezelStyle = .rounded
            control.font = .systemFont(ofSize: 11)
            control.imagePosition = .imageLeading
        case .icon:
            control.bezelStyle = .inline
            control.title = ""
            control.imagePosition = .imageOnly
            control.contentTintColor = NSColor.white.withAlphaComponent(0.7)
            control.widthAnchor.constraint(equalToConstant: 20).isActive = true
            control.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        return control
    }

    // MARK: - 正文

    /// 结果正文：非编辑但可选，按词换行、最多 `lines` 行尾部截断。
    ///
    /// 这里不能用 `NSTextField(labelWithString:)`：那是标签字段，事后设
    /// `isSelectable` 并不会让 AppKit 装字段编辑器，点上去既选不中也复制不了。
    func payloadField(
        _ payload: BarcodePayload,
        lines: Int,
        maxWidth: CGFloat = contentWidth
    ) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = lines
        field.preferredMaxLayoutWidth = maxWidth
        field.attributedStringValue = attributedPayload(payload)
        field.toolTip = payload.text
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        field.setAccessibilityLabel(payload.text)
        return field
    }

    /// 链接类拆「域名 / 其余」两级：域名半粗、路径等宽降级，一眼看出去哪。
    func attributedPayload(_ payload: BarcodePayload) -> NSAttributedString {
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
        ]
        let text = NSMutableAttributedString()

        if let url = payload.webLink,
           let host = url.host,
           let hostRange = payload.text.range(of: host) {
            text.append(
                NSAttributedString(
                    string: String(payload.text[..<hostRange.lowerBound]),
                    attributes: secondary
                )
            )
            text.append(
                NSAttributedString(
                    string: host,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.94),
                    ]
                )
            )
            text.append(
                NSAttributedString(
                    string: String(payload.text[hostRange.upperBound...]),
                    attributes: secondary
                )
            )
        } else {
            text.append(
                NSAttributedString(
                    string: payload.text,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.94),
                    ]
                )
            )
        }
        return text
    }

    // MARK: - 文本

    func badge(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 10, weight: .semibold)
        field.textColor = .white
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        field.layer?.cornerRadius = 4
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        field.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return field
    }

    func label(
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
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        if lines > 1 {
            // 标签默认单行：多行态要打开换行，否则提示文案会被截成一行。
            field.cell?.wraps = true
            field.usesSingleLineMode = false
            field.preferredMaxLayoutWidth = maxWidth
        }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        return field
    }
}

// MARK: - ClosureButton

/// 面板里的按钮只做一件事，用闭包比逐个开 selector 更省。
final class ClosureButton: NSButton {
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
