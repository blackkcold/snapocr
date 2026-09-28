import AppKit
import KeyboardShortcuts
import Testing

@testable import SharedKit

@Suite(.serialized)
struct PinSelectionShortcutTests {
    private static let pKeyCode: UInt16 = 35
    private static let yKeyCode: UInt16 = 16

    @Test func unsetPreferenceFallsBackToCommandP() {
        PinSelectionShortcut.resetToDefault()
        #expect(PinSelectionShortcut.current == PinSelectionShortcut.fallbackDefault)
        #expect(PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command]))
    }

    @Test func customShortcutReplacesFallback() {
        PinSelectionShortcut.set(.init(.y, modifiers: [.command, .shift]))

        #expect(PinSelectionShortcut.matches(keyCode: Self.yKeyCode, modifiers: [.command, .shift]))
        #expect(!PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command]))

        PinSelectionShortcut.resetToDefault()
        #expect(PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command]))
    }

    @Test func clearedShortcutMatchesNothing() throws {
        PinSelectionShortcut.clear()

        let event = try #require(Self.event(keyCode: Self.pKeyCode, modifiers: [.command]))

        #expect(PinSelectionShortcut.current == nil)
        #expect(!PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command]))
        #expect(!PinSelectionShortcut.matches(event: event))

        PinSelectionShortcut.resetToDefault()
    }

    @Test func capsLockNumericPadAndFunctionDoNotBreakMatching() {
        PinSelectionShortcut.set(.init(.p, modifiers: [.command]))

        #expect(PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command, .capsLock]))
        #expect(PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command, .numericPad]))
        #expect(PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command, .function]))
        #expect(
            PinSelectionShortcut.matches(
                keyCode: Self.pKeyCode,
                modifiers: [.command, .capsLock, .numericPad]
            )
        )

        PinSelectionShortcut.resetToDefault()
    }

    @Test func extraModifierDoesNotMatch() {
        PinSelectionShortcut.set(.init(.p, modifiers: [.command]))
        #expect(!PinSelectionShortcut.matches(keyCode: Self.pKeyCode, modifiers: [.command, .shift]))
        PinSelectionShortcut.resetToDefault()
    }

    @Test func matchesEventUsesKeyCodeAndModifiers() throws {
        PinSelectionShortcut.set(.init(.p, modifiers: [.command]))

        let matching = try #require(Self.event(keyCode: Self.pKeyCode, modifiers: [.command]))
        let bare = try #require(Self.event(keyCode: Self.pKeyCode, modifiers: []))

        #expect(PinSelectionShortcut.matches(event: matching))
        #expect(!PinSelectionShortcut.matches(event: bare))

        PinSelectionShortcut.resetToDefault()
    }

    @Test func conflictingGlobalShortcutsAreRejected() {
        #expect(PinSelectionShortcut.conflictsWithGlobalShortcuts(.init(.one, modifiers: [.command, .shift])))
        #expect(PinSelectionShortcut.conflictsWithGlobalShortcuts(.init(.two, modifiers: [.command, .shift])))
        #expect(PinSelectionShortcut.conflictsWithGlobalShortcuts(.init(.three, modifiers: [.command, .shift])))
        #expect(PinSelectionShortcut.conflictsWithGlobalShortcuts(.init(.o, modifiers: [.command, .shift])))
        #expect(!PinSelectionShortcut.conflictsWithGlobalShortcuts(.init(.p, modifiers: [.command])))
    }

    @Test func storageUsesOwnedKeyAndResetRemovesOverride() {
        PinSelectionShortcut.set(.init(.y, modifiers: [.command, .shift]))

        #expect(UserDefaults.standard.string(forKey: PreferenceKeys.pinSelectionShortcut) != nil)
        #expect(!PreferenceKeys.pinSelectionShortcut.hasPrefix("KeyboardShortcuts_"))

        PinSelectionShortcut.resetToDefault()
        #expect(UserDefaults.standard.string(forKey: PreferenceKeys.pinSelectionShortcut) == nil)
        #expect(PinSelectionShortcut.current == PinSelectionShortcut.fallbackDefault)
    }

    @Test func recordingRejectsUnmodifiedAndShiftOnlyCombos() {
        #expect(PinSelectionShortcut.recordingRejection(for: .init(.p, modifiers: [])) == .needsModifier)
        #expect(PinSelectionShortcut.recordingRejection(for: .init(.p, modifiers: [.shift])) == .needsModifier)
        #expect(PinSelectionShortcut.recordingRejection(for: .init(.f5, modifiers: [])) == nil)
        #expect(PinSelectionShortcut.recordingRejection(for: .init(.p, modifiers: [.command])) == nil)
    }

    @Test func recordingRejectsOverlayAndGlobalConflicts() {
        #expect(PinSelectionShortcut.recordingRejection(for: .init(.e, modifiers: [.command])) == .reservedByOverlay)
        #expect(
            PinSelectionShortcut.recordingRejection(for: .init(.return, modifiers: [.command])) == .reservedByOverlay
        )
        #expect(
            PinSelectionShortcut.recordingRejection(for: .init(.escape, modifiers: [.command])) == .reservedByOverlay
        )
        #expect(
            PinSelectionShortcut.recordingRejection(for: .init(.one, modifiers: [.command, .shift]))
                == .reservedByGlobalShortcut
        )
        #expect(PinSelectionShortcut.recordingRejection(for: .init(.p, modifiers: [.command])) == nil)
    }

    private static func event(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
