import AppKit
import SharedKit
import SwiftUI

// MARK: - CaptureActionBarView

final class CaptureActionBarView: NSVisualEffectView {
    var onBack: (() -> Void)?
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?

    private let backButton = NSButton()
    private let copyButton = NSButton()
    private let editButton = NSButton()
    private let pinButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        configureActionButtons()

        let stack = NSStackView(views: [backButton, copyButton, editButton, pinButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(
            AppLocalization.string("Screenshot Actions")
        )
    }

    private func configureActionButtons() {
        configure(
            backButton,
            title: AppLocalization.string("Back"),
            symbol: "chevron.backward",
            toolTip: AppLocalization.string("Return to selection adjustments"),
            action: #selector(back)
        )
        backButton.keyEquivalent = "\u{1b}"

        configure(
            copyButton,
            title: AppLocalization.string("Copy Image"),
            symbol: "doc.on.doc",
            toolTip: AppLocalization.string("Copy the screenshot to the clipboard"),
            action: #selector(copyImage)
        )
        copyButton.keyEquivalent = "\r"

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        for button in [backButton, copyButton, editButton, pinButton]
        where button.convert(button.bounds, to: self).contains(point) {
            return button
        }
        return super.hitTest(point)
    }

    func focusDefaultAction() {
        window?.makeFirstResponder(copyButton)
    }

    func performAction(at point: NSPoint) -> Bool {
        let actions: [(NSButton, () -> Void)] = [
            (backButton, { [weak self] in self?.onBack?() }),
            (copyButton, { [weak self] in self?.onCopy?() }),
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

    @objc private func back() { onBack?() }
    @objc private func copyImage() { onCopy?() }
    @objc private func editScreenshot() { onEdit?() }
    @objc private func pinImage() { onPin?() }
}
