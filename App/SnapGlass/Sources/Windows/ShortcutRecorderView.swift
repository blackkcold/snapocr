import AppKit
import KeyboardShortcuts
import SharedKit
import SwiftUI

/// Records a shortcut for ``PinSelectionShortcut`` without touching the global
/// `KeyboardShortcuts` storage.
struct ShortcutRecorderView: NSViewRepresentable {
    let shortcut: PinSelectionShortcut.Shortcut?
    let onRecord: (PinSelectionShortcut.Shortcut) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onClear = onClear
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onClear = onClear
        if nsView.shortcut != shortcut {
            nsView.shortcut = shortcut
        }
    }

    final class RecorderView: NSView {
        var onRecord: ((PinSelectionShortcut.Shortcut) -> Void)?
        var onClear: (() -> Void)?

        var shortcut: PinSelectionShortcut.Shortcut? {
            didSet { needsDisplay = true }
        }

        private var isRecording = false
        private var eventMonitor: Any?
        private var trackingAreaReference: NSTrackingArea?

        override var acceptsFirstResponder: Bool { true }

        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            let fillColor = isRecording
                ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                : NSColor.controlBackgroundColor
            fillColor.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let text = displayText
            let isPlaceholder = shortcut == nil && !isRecording
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: isPlaceholder ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            text.draw(at: origin, withAttributes: attributes)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { startRecording() }
            return result
        }

        override func resignFirstResponder() -> Bool {
            stopRecording()
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            if window == nil { stopRecording() }
        }

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
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == Self.escapeKeyCode {
                endRecording()
                return
            }
            if event.keyCode == Self.deleteKeyCode || event.keyCode == Self.forwardDeleteKeyCode {
                shortcut = nil
                onClear?()
                endRecording()
                return
            }
            guard let candidate = PinSelectionShortcut.Shortcut(event: event) else {
                NSSound.beep()
                return
            }
            guard PinSelectionShortcut.recordingRejection(for: candidate) == nil else {
                NSSound.beep()
                return
            }
            shortcut = candidate
            onRecord?(candidate)
            endRecording()
        }

        private var displayText: String {
            if isRecording { return AppLocalization.string("Press shortcut…") }
            guard let shortcut else { return AppLocalization.string("Click to record") }
            return shortcut.description
        }

        private func startRecording() {
            guard !isRecording else { return }
            isRecording = true
            needsDisplay = true
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, isRecording else { return event }
                keyDown(with: event)
                return nil
            }
        }

        private func endRecording() {
            stopRecording()
            window?.makeFirstResponder(nil)
        }

        private func stopRecording() {
            guard isRecording else { return }
            isRecording = false
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            needsDisplay = true
        }

        private static let escapeKeyCode: UInt16 = 53
        private static let deleteKeyCode: UInt16 = 51
        private static let forwardDeleteKeyCode: UInt16 = 117
    }
}
