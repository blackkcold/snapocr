import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SharedKit

/// Probes whether a shortcut can actually be registered right now.
///
/// This is the only way to detect a shortcut already held by another app.
/// `KeyboardShortcuts` registers through `RegisterEventHotKey` but swallows the
/// failure: `CarbonKeyboardShortcuts.register` prints and returns, so a
/// conflicting key looks assigned while doing nothing. Reading
/// `Shortcut.isTakenBySystem` is not an option either — it is `internal` — and it
/// only covers Apple's own reservations, not other apps.
@MainActor
enum ShortcutConflictProbe {
    /// Signature identifying SnapGlass probes. Distinct from the one
    /// `KeyboardShortcuts` uses so a probe can never be mistaken for a real hot key.
    private static let probeSignature: OSType = 0x5347_5052  // "SGPR"

    /// Attempts to register `shortcut`, then immediately unregisters it.
    ///
    /// - Parameter shortcut: The combination to test.
    /// - Returns: The conflict found. `.unknown` when the API refuses for a reason
    ///   other than "already exists"; callers treat it as "no conflict found".
    static func probe(_ shortcut: KeyboardShortcuts.Shortcut) -> ShortcutConflict {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.carbonKeyCode),
            UInt32(shortcut.carbonModifiers),
            EventHotKeyID(signature: probeSignature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        if let reference {
            UnregisterEventHotKey(reference)
        }

        if status == noErr {
            return .none
        }
        if status == OSStatus(eventHotKeyExistsErr) {
            return .takenByAnotherApp
        }
        return .unknown
    }

    /// Probes a shortcut slot after temporarily releasing it.
    ///
    /// Every `KeyboardShortcuts` slot must be disabled first, otherwise the app's
    /// own registration is what the probe collides with and every assigned shortcut
    /// would report a conflict.
    ///
    /// - Parameters:
    ///   - shortcut: The combination to test.
    ///   - name: The slot the combination belongs to; released for the duration.
    /// - Returns: The conflict found, `nil` when the combination is unset.
    static func probe(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) -> ShortcutConflict? {
        guard let shortcut else { return nil }

        let others = Self.otherAssignments(excluding: name)
        let staticConflict = ShortcutConflictDetector.conflict(for: shortcut, among: others)
        if staticConflict != .none {
            return staticConflict
        }

        // Release the app's own registration so the probe measures reality rather
        // than colliding with SnapGlass itself.
        let wasEnabled = KeyboardShortcuts.getShortcut(for: name) != nil
        if wasEnabled {
            KeyboardShortcuts.disable(name)
        }
        let result = probe(shortcut)
        if wasEnabled {
            KeyboardShortcuts.enable(name)
        }
        return result
    }

    /// Every assigned shortcut except `excluded`, for in-app duplicate detection.
    ///
    /// - Parameter excluded: The slot being changed.
    /// - Returns: One assignment per slot that currently holds a shortcut.
    static func otherAssignments(excluding excluded: KeyboardShortcuts.Name) -> [ShortcutAssignment] {
        Self.slots.compactMap { slot in
            guard slot.name.rawValue != excluded.rawValue,
                let shortcut = KeyboardShortcuts.getShortcut(for: slot.name)
            else { return nil }
            return ShortcutAssignment(action: slot.actionKey, shortcut: shortcut)
        }
    }

    /// A shortcut slot with the localization key naming it.
    struct Slot {
        /// The `KeyboardShortcuts` slot.
        let name: KeyboardShortcuts.Name
        /// Localization key naming the action, reused from the existing catalog.
        let actionKey: String
    }

    /// Slots the guide offers for editing, in display order.
    static let slots: [Slot] = [
        Slot(name: .captureArea, actionKey: "Area Capture"),
        Slot(name: .captureWindow, actionKey: "Window Capture"),
        Slot(name: .screenRecording, actionKey: "Screen Recording"),
    ]
}
