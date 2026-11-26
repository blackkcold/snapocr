import AppKit
import Foundation
import KeyboardShortcuts
import Testing

@testable import SharedKit

struct ShortcutConflictTests {
    private func shortcut(
        _ key: KeyboardShortcuts.Key,
        _ modifiers: NSEvent.ModifierFlags
    ) -> KeyboardShortcuts.Shortcut {
        KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
    }

    // MARK: - In-app duplicates

    @Test func detectsInAppDuplicate() {
        let area = ShortcutAssignment(
            action: "Area Capture",
            shortcut: shortcut(.one, [.command, .shift])
        )
        let conflict = ShortcutConflictDetector.conflict(
            for: shortcut(.one, [.command, .shift]),
            among: [area]
        )
        #expect(conflict == .duplicateInApp(action: "Area Capture"))
    }

    @Test func differentModifiersAreNotDuplicates() {
        let area = ShortcutAssignment(
            action: "Area Capture",
            shortcut: shortcut(.one, [.command, .shift])
        )
        let conflict = ShortcutConflictDetector.conflict(
            for: shortcut(.one, [.command]),
            among: [area]
        )
        #expect(conflict == .none)
    }

    @Test func differentKeyIsNotDuplicate() {
        let area = ShortcutAssignment(
            action: "Area Capture",
            shortcut: shortcut(.one, [.command, .shift])
        )
        let conflict = ShortcutConflictDetector.conflict(
            for: shortcut(.two, [.command, .shift]),
            among: [area]
        )
        #expect(conflict == .none)
    }

    // MARK: - System reservations

    @Test func detectsSystemScreenshotShortcuts() {
        for key in [KeyboardShortcuts.Key.three, .four, .five] {
            let conflict = ShortcutConflictDetector.conflict(
                for: shortcut(key, [.command, .shift]),
                among: []
            )
            #expect(conflict == .systemReserved)
        }
    }

    @Test func detectsOtherReservedCombinations() {
        let reserved: [(KeyboardShortcuts.Key, NSEvent.ModifierFlags)] = [
            (.space, [.command]),
            (.escape, [.command, .option]),
            (.q, [.command, .shift]),
            (.q, [.command, .control]),
            (.f, [.command, .control]),
            (.period, [.command, .shift]),
            (.backslash, [.command, .option]),
        ]
        for (key, modifiers) in reserved {
            let conflict = ShortcutConflictDetector.conflict(
                for: shortcut(key, modifiers),
                among: []
            )
            #expect(conflict == .systemReserved)
        }
    }

    @Test func plainLetterIsNotReserved() {
        let conflict = ShortcutConflictDetector.conflict(
            for: shortcut(.k, [.command, .shift]),
            among: []
        )
        #expect(conflict == .none)
    }

    // MARK: - Priority

    @Test func inAppDuplicateWinsOverSystemReservation() {
        // ⌘⇧3 is reserved by macOS, but if SnapGlass itself already bound it, the
        // in-app answer is the actionable one.
        let capture = ShortcutAssignment(
            action: "Fullscreen Capture",
            shortcut: shortcut(.three, [.command, .shift])
        )
        let conflict = ShortcutConflictDetector.conflict(
            for: shortcut(.three, [.command, .shift]),
            among: [capture]
        )
        #expect(conflict == .duplicateInApp(action: "Fullscreen Capture"))
    }

    // MARK: - Normalization

    @Test func capsLockDoesNotChangeIdentity() {
        // Caps Lock and the fn flag arrive depending on the keyboard; they must not
        // make the same combination compare as different.
        let plain = shortcut(.one, [.command, .shift])
        let withCaps = KeyboardShortcuts.Shortcut(
            carbonKeyCode: plain.carbonKeyCode,
            carbonModifiers: plain.carbonModifiers
        )
        #expect(ShortcutConflictDetector.isSame(plain, withCaps))
    }

    @Test func catalogHasNoDuplicateEntries() {
        // A duplicated entry would report the wrong reason for a real conflict.
        for (index, entry) in SystemShortcutCatalog.entries.enumerated() {
            for other in SystemShortcutCatalog.entries[(index + 1)...] {
                #expect(
                    !ShortcutConflictDetector.isSame(entry.shortcut, other.shortcut),
                    "duplicate catalog entry: \(entry.reason) vs \(other.reason)"
                )
            }
        }
    }

    @Test func everyCatalogEntryIsReportedAsReserved() {
        for entry in SystemShortcutCatalog.entries {
            #expect(SystemShortcutCatalog.reserves(entry.shortcut), "not detected: \(entry.reason)")
        }
    }
}
