import AppKit

/// A keyboard command issued while the shelf has keyboard focus.
enum ScreenshotShelfKeyboardCommand: Equatable {
    case focusPrevious
    case focusNext
    case copyFocused
    case openFocused
    case saveFocused
    case openMockup
    case toggleMockup
    case cycleMockup
    case removeFocused
    case exit
    case ignore

    // Key mapping is intentionally a flat lookup table; splitting it would
    // make the reserved/ignored combinations harder to audit.
    // swiftlint:disable:next cyclomatic_complexity
    static func command(
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> ScreenshotShelfKeyboardCommand {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch characters.lowercased() {
            case "s": return .saveFocused
            case "b": return .openMockup
            default: return .ignore
            }
        }
        guard !flags.contains(.option), !flags.contains(.control) else { return .ignore }
        if flags.contains(.shift), characters.lowercased() == "b" {
            return .cycleMockup
        }

        switch characters {
        case "b":
            return .toggleMockup
        case "\u{F702}":
            return .focusPrevious
        case "\u{F703}":
            return .focusNext
        case "\r", "\u{3}":
            return .copyFocused
        case " ":
            return .openFocused
        case "\u{7F}", "\u{F728}":
            return .removeFocused
        case "\u{1B}":
            return .exit
        default:
            return .ignore
        }
    }
}

/// Drives the shelf from the keyboard.
///
/// The shelf is a nonactivating panel: entering keyboard mode flips
/// `canBecomeKey` for the duration and makes the panel key without bringing the
/// app forward. Leaving the mode resigns the key window, so the user's
/// keystrokes go back to whatever app they were using.
@MainActor
final class ScreenshotShelfKeyboardController {
    private weak var panel: ScreenshotShelfPanel?
    private let model: ScreenshotShelfViewModel
    private let onCopy: (UUID) -> Void
    private let onOpen: (UUID) -> Void
    private let onSave: (UUID) -> Void
    private let onOpenMockup: (UUID) -> Void
    private let onToggleMockup: (UUID) -> Void
    private let onCycleMockup: (UUID) -> Void
    private let onRemove: (UUID) -> Void

    private var isActive = false
    private nonisolated(unsafe) var resignObserver: NSObjectProtocol?

    init(
        model: ScreenshotShelfViewModel,
        onCopy: @escaping (UUID) -> Void,
        onOpen: @escaping (UUID) -> Void,
        onSave: @escaping (UUID) -> Void,
        onOpenMockup: @escaping (UUID) -> Void,
        onToggleMockup: @escaping (UUID) -> Void,
        onCycleMockup: @escaping (UUID) -> Void,
        onRemove: @escaping (UUID) -> Void
    ) {
        self.model = model
        self.onCopy = onCopy
        self.onOpen = onOpen
        self.onSave = onSave
        self.onOpenMockup = onOpenMockup
        self.onToggleMockup = onToggleMockup
        self.onCycleMockup = onCycleMockup
        self.onRemove = onRemove
    }

    func attach(panel: ScreenshotShelfPanel) {
        self.panel = panel
    }

    /// Enters keyboard mode. Returns `false` when the shelf has nothing to focus.
    @discardableResult
    func enter() -> Bool {
        guard let panel, !model.layout.cards.isEmpty else { return false }
        guard !isActive else { return true }

        isActive = true
        panel.isKeyboardMode = true
        panel.keyHandler = { [weak self] event in
            self?.handle(event) ?? false
        }
        panel.makeKey()
        observeResign(for: panel)

        if model.focusedCaptureID == nil {
            model.setFocusedCapture(model.layout.cards.first?.captureID)
        }
        return true
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        removeResignObserver()
        model.setFocusedCapture(nil)
        guard let panel else { return }
        panel.keyHandler = nil
        panel.isKeyboardMode = false
        panel.resignKey()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let command = ScreenshotShelfKeyboardCommand.command(
            characters: event.charactersIgnoringModifiers ?? "",
            modifiers: event.modifierFlags
        )

        switch command {
        case .ignore:
            return false
        case .exit:
            exit()
            return true
        case .focusPrevious:
            return moveFocus(by: -1)
        case .focusNext:
            return moveFocus(by: 1)
        case .copyFocused:
            return performFocused(onCopy)
        case .openFocused:
            return performFocused(onOpen)
        case .saveFocused:
            return performFocused(onSave)
        case .openMockup:
            return performFocused(onOpenMockup)
        case .toggleMockup:
            return performFocused(onToggleMockup)
        case .cycleMockup:
            return performFocused(onCycleMockup)
        case .removeFocused:
            return performFocused(onRemove)
        }
    }

    private func moveFocus(by offset: Int) -> Bool {
        let ids = model.layout.cards.map(\.captureID)
        guard !ids.isEmpty else { return false }
        let current = model.focusedCaptureID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = min(max(current + offset, 0), ids.count - 1)
        model.setFocusedCapture(ids[next])
        return true
    }

    private func performFocused(_ action: (UUID) -> Void) -> Bool {
        guard let captureID = model.focusedCaptureID else { return false }
        action(captureID)
        return true
    }

    private func observeResign(for panel: ScreenshotShelfPanel) {
        removeResignObserver()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.exit()
            }
        }
    }

    private func removeResignObserver() {
        guard let resignObserver else { return }
        NotificationCenter.default.removeObserver(resignObserver)
        self.resignObserver = nil
    }
}
