import AppKit
import SharedKit
import SwiftUI

// MARK: - CaptureActionBarView

final class CaptureActionBarView: NSVisualEffectView {
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?
    var onScan: (() -> Void)?

    private let copyButton = NSButton()
    private let scanButton = NSButton()
    private let editButton = NSButton()
    private let pinButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        // 宿主 `AreaSelectionPanel` 是 clear + 非 opaque：窗内没有可采样的内容，
        // `.withinWindow` 只会退化成一块灰底。改用 `.behindWindow` 采桌面，
        // 与 `PinnedToolbarView` 保持一致。
        blendingMode = .behindWindow
        // HUD 恒定深色：按钮标题等语义色据此解析，浅色系统下不会变成黑字。
        appearance = NSAppearance(named: .darkAqua)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = DS.Corner.c10
        layer?.masksToBounds = true

        configureActionButtons()

        let stack = NSStackView(views: [copyButton, scanButton, editButton, pinButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = DS.Space.s8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DS.Space.s8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DS.Space.s8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.s10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.s10),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            AppLocalization.string("Screenshot Actions")
        )
    }

    private func configureActionButtons() {
        configure(
            copyButton,
            title: AppLocalization.string("Copy Image"),
            symbol: "doc.on.doc",
            toolTip: AppLocalization.string("Copy the screenshot to the clipboard"),
            action: #selector(copyImage)
        )
        copyButton.keyEquivalent = "\r"

        configure(
            scanButton,
            title: AppLocalization.string("Scan Selection"),
            symbol: "qrcode.viewfinder",
            toolTip: AppLocalization.string("Scan the selected area for a QR code or barcode"),
            action: #selector(scanSelection)
        )
        scanButton.keyEquivalent = "s"

        configure(
            editButton,
            title: AppLocalization.string("Edit Screenshot"),
            symbol: "pencil.and.outline",
            toolTip: AppLocalization.string("Open the screenshot in the annotation editor"),
            action: #selector(editScreenshot)
        )
        editButton.keyEquivalent = "e"

        configure(
            pinButton,
            title: AppLocalization.string("Pin Image"),
            symbol: "pin",
            toolTip: AppLocalization.string("Pin the screenshot as a floating panel"),
            action: #selector(pinImage)
        )
        // The pin shortcut is matched locally by `AreaTrackingView` so it can be
        // user-configured; a `keyEquivalent` here would bypass that and shadow it.
    }

    /// Refreshes the pin tooltip with the currently configured shortcut.
    func updatePinShortcutHint() {
        let base = AppLocalization.string("Pin the screenshot as a floating panel")
        guard let shortcut = PinSelectionShortcut.current else {
            pinButton.toolTip = base
            return
        }
        pinButton.toolTip = "\(base) (\(shortcut))"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 识别中：按钮文案换「识别中…」并禁用，避免重复起任务。
    func setScanning(_ isScanning: Bool) {
        scanButton.title = isScanning
            ? AppLocalization.string("Scanning…")
            : AppLocalization.string("Scan Selection")
        scanButton.isEnabled = !isScanning
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for button in [copyButton, scanButton, editButton, pinButton]
        where button.convert(button.bounds, to: self).contains(point) {
            return button
        }
        return super.hitTest(point)
    }

    func performAction(at point: NSPoint) -> Bool {
        let actions: [(NSButton, () -> Void)] = [
            (copyButton, { [weak self] in self?.onCopy?() }),
            (scanButton, { [weak self] in self?.onScan?() }),
            (editButton, { [weak self] in self?.onEdit?() }),
            (pinButton, { [weak self] in self?.onPin?() }),
        ]
        guard let action = actions.first(where: { button, _ in
            button.convert(button.bounds, to: self).contains(point)
        })?.1 else {
            return false
        }
        action()
        return true
    }

    private func configure(
        _ button: NSButton,
        title: String,
        symbol: String,
        toolTip: String,
        action: Selector
    ) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
    }

    @objc private func copyImage() { onCopy?() }
    @objc private func scanSelection() { onScan?() }
    @objc private func editScreenshot() { onEdit?() }
    @objc private func pinImage() { onPin?() }
}
