import AppKit
import Testing

@MainActor
struct ScreenshotShelfKeyboardCommandTests {
    @Test func arrowsMoveTheFocus() {
        #expect(
            ScreenshotShelfKeyboardCommand.command(
                characters: "\u{F702}",
                modifiers: []
            ) == .focusPrevious
        )
        #expect(
            ScreenshotShelfKeyboardCommand.command(
                characters: "\u{F703}",
                modifiers: []
            ) == .focusNext
        )
    }

    @Test func returnCopiesTheFocusedCard() {
        #expect(
            ScreenshotShelfKeyboardCommand.command(characters: "\r", modifiers: []) == .copyFocused
        )
    }

    @Test func spaceOpensTheFocusedCard() {
        #expect(
            ScreenshotShelfKeyboardCommand.command(characters: " ", modifiers: []) == .openFocused
        )
    }

    @Test func deleteRemovesTheFocusedCard() {
        #expect(
            ScreenshotShelfKeyboardCommand.command(characters: "\u{7F}", modifiers: [])
                == .removeFocused
        )
    }

    @Test func escapeLeavesKeyboardMode() {
        #expect(ScreenshotShelfKeyboardCommand.command(characters: "\u{1B}", modifiers: []) == .exit)
    }

    @Test func commandSavesTheFocusedCard() {
        #expect(
            ScreenshotShelfKeyboardCommand.command(characters: "s", modifiers: [.command])
                == .saveFocused
        )
        #expect(
            ScreenshotShelfKeyboardCommand.command(characters: "S", modifiers: [.command, .shift])
                == .saveFocused
        )
    }

    @Test func otherModifiedKeysAreIgnored() {
        #expect(
            ScreenshotShelfKeyboardCommand.command(characters: "c", modifiers: [.command]) == .ignore
        )
        #expect(
            ScreenshotShelfKeyboardCommand.command(characters: "\u{F702}", modifiers: [.option])
                == .ignore
        )
    }

    @Test func typingIsIgnored() {
        #expect(ScreenshotShelfKeyboardCommand.command(characters: "a", modifiers: []) == .ignore)
    }
}
