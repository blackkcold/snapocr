import AppKit
import Foundation
import KeyboardShortcuts

/// The user-configurable shortcut that pins the current area selection.
///
/// Deliberately bypasses the `KeyboardShortcuts` storage and registration path
/// (`setShortcut` / `Recorder` / `reset`); only `Shortcut` is reused as a type.
public enum PinSelectionShortcut {
    /// The reusable shortcut value type.
    public typealias Shortcut = KeyboardShortcuts.Shortcut

    /// Code-level fallback used while the user never changed the shortcut.
    public static let fallbackDefault = Shortcut(.p, modifiers: [.command])

    /// Effective shortcut, or `nil` after an explicit ``clear()``.
    public static var current: Shortcut? {
        switch load() {
        case .unset:
            return fallbackDefault
        case .cleared:
            return nil
        case .shortcut(let shortcut):
            return shortcut
        }
    }

    /// Persists `shortcut`; pass `nil` to clear it explicitly.
    public static func set(_ shortcut: Shortcut?) {
        write(Stored(shortcut: shortcut))
    }

    /// Restores ``fallbackDefault`` by removing the stored override.
    ///
    /// Removing the override (instead of writing ⌘P) keeps ``current`` in sync
    /// with ``fallbackDefault`` even if the code-level default changes later.
    public static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: PreferenceKeys.pinSelectionShortcut)
    }

    /// Makes the pin shortcut inactive while the action bar button still works.
    public static func clear() {
        set(nil)
    }

    /// Whether a raw key press matches the effective pin shortcut.
    public static func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let shortcut = current else {
            return false
        }
        return Int(keyCode) == shortcut.carbonKeyCode && normalize(modifiers) == shortcut.modifiers
    }

    /// Whether a key-down event matches the effective pin shortcut.
    public static func matches(event: NSEvent) -> Bool {
        matches(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// Whether `shortcut` is already taken by one of the four global shortcuts.
    ///
    /// Used by the recorder to reject a conflicting recording before it is stored.
    public static func conflictsWithGlobalShortcuts(_ shortcut: Shortcut) -> Bool {
        globalNames.contains { name in
            guard let active = KeyboardShortcuts.getShortcut(for: name) ?? name.defaultShortcut else {
                return false
            }
            return active == shortcut
        }
    }

    /// Whether `shortcut` collides with a key the area overlay already handles.
    public static func conflictsWithOverlayShortcuts(_ shortcut: Shortcut) -> Bool {
        overlayReservedKeys.contains { shortcut == .init($0, modifiers: [.command]) }
    }

    /// Reason a candidate shortcut cannot be recorded, or `nil` when it is usable.
    public enum RecordingRejection: Sendable {
        /// No usable modifier and not a function key; the combo is unreachable.
        case needsModifier
        /// Already bound by the overlay's own action bar.
        case reservedByOverlay
        /// Already bound by one of the four global capture shortcuts.
        case reservedByGlobalShortcut
    }

    /// Validates a candidate shortcut before it is stored.
    public static func recordingRejection(for shortcut: Shortcut) -> RecordingRejection? {
        // Shift alone and the Fn flag do not work as standalone modifiers, matching
        // how the recorder for the global shortcuts behaves.
        let usableModifiers = shortcut.modifiers.subtracting([.shift, .function])
        if usableModifiers.isEmpty, !(shortcut.key.map(isFunctionKey) ?? false) {
            return .needsModifier
        }
        if conflictsWithOverlayShortcuts(shortcut) {
            return .reservedByOverlay
        }
        if conflictsWithGlobalShortcuts(shortcut) {
            return .reservedByGlobalShortcut
        }
        return nil
    }

    // MARK: - Helpers

    /// Strips device-dependent and non-semantic flags before comparing modifiers.
    ///
    /// Caps Lock, the numeric-pad flag added by arrow keys, and the Fn flag must
    /// never influence a match; otherwise the same combo would stop working
    /// depending on which keyboard or modifier state produced the event.
    static func normalize(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    private static let globalNames: [KeyboardShortcuts.Name] = [
        .captureArea,
        .captureWindow,
        .captureFullscreen,
        .ocrFromClipboard,
    ]

    private static let overlayReservedKeys: [KeyboardShortcuts.Key] = [
        .e,
        .return,
        .keypadEnter,
        .escape,
    ]

    private static let functionKeys: Set<KeyboardShortcuts.Key> = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ]

    private static func isFunctionKey(_ key: KeyboardShortcuts.Key) -> Bool {
        functionKeys.contains(key)
    }

    private enum Storage {
        case unset
        case cleared
        case shortcut(Shortcut)
    }

    /// Wrapper so the stored JSON is always a valid object.
    ///
    /// A top-level JSON `null` is not portable across Foundation versions, so the
    /// "cleared" state is encoded as `{"shortcut":null}` instead.
    private struct Stored: Codable {
        let shortcut: Shortcut?
    }

    private static func load() -> Storage {
        guard
            let raw = UserDefaults.standard.string(forKey: PreferenceKeys.pinSelectionShortcut),
            let data = raw.data(using: .utf8),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            return .unset
        }
        return stored.shortcut.map(Storage.shortcut) ?? .cleared
    }

    private static func write(_ stored: Stored) {
        guard
            let data = try? JSONEncoder().encode(stored),
            let raw = String(data: data, encoding: .utf8)
        else {
            return
        }
        UserDefaults.standard.set(raw, forKey: PreferenceKeys.pinSelectionShortcut)
    }
}
