import Foundation
import Testing
@testable import LibraryCore

@Suite("Library command router")
struct LibraryCommandRouterTests {
    @Test("Every command's shortcut maps back to itself")
    func shortcutRoundTrip() {
        for command in LibraryCommand.allCases {
            #expect(
                LibraryCommandRouter.command(
                    for: command.key,
                    modifiers: command.modifiers
                ) == command
            )
        }
    }

    @Test("Shortcut matrix matches the documented library keys")
    func keyMappings() {
        #expect(LibraryCommandRouter.command(for: "space", modifiers: []) == .preview)
        #expect(LibraryCommandRouter.command(for: "space", modifiers: [.command]) == nil)
        #expect(LibraryCommandRouter.command(for: "return", modifiers: []) == .open)
        #expect(LibraryCommandRouter.command(for: "e", modifiers: [.command]) == .export)
        #expect(LibraryCommandRouter.command(for: "delete", modifiers: [.command]) == .delete)
        #expect(LibraryCommandRouter.command(for: "f", modifiers: [.command, .shift]) == .favourite)
        #expect(LibraryCommandRouter.command(for: "a", modifiers: [.command]) == .selectAll)
        #expect(LibraryCommandRouter.command(for: "escape", modifiers: []) == .cancel)
        #expect(LibraryCommandRouter.command(for: "F", modifiers: [.command, .shift]) == .favourite)
        #expect(LibraryCommandRouter.command(for: "x", modifiers: []) == nil)
        #expect(LibraryCommandRouter.command(for: "e", modifiers: []) == nil)
    }

    @Test("Commands are disabled when their context is unavailable")
    func availability() {
        let empty = LibraryCommandContext()
        for command in LibraryCommand.allCases {
            #expect(!LibraryCommandRouter.isEnabled(command, context: empty))
        }

        let selected = LibraryCommandContext(
            hasSelection: true,
            visibleItemCount: 1,
            canOpen: true,
            canExport: true,
            canDelete: true,
            canFavourite: true,
            isSelecting: true
        )
        for command in LibraryCommand.allCases {
            #expect(LibraryCommandRouter.isEnabled(command, context: selected))
        }

        // A sheet owns the keyboard even when a row is selected.
        var sheet = selected
        sheet.isSheetPresented = true
        for command in LibraryCommand.allCases {
            #expect(!LibraryCommandRouter.isEnabled(command, context: sheet))
        }

        // Availability is per command, not one shared "has selection" flag.
        var partial = selected
        partial.canExport = false
        #expect(LibraryCommandRouter.isEnabled(.preview, context: partial))
        #expect(!LibraryCommandRouter.isEnabled(.export, context: partial))
        partial.canFavourite = false
        #expect(!LibraryCommandRouter.isEnabled(.favourite, context: partial))

        let nothingVisible = LibraryCommandContext(visibleItemCount: 0)
        #expect(!LibraryCommandRouter.isEnabled(.selectAll, context: nothingVisible))
        let visible = LibraryCommandContext(visibleItemCount: 3)
        #expect(LibraryCommandRouter.isEnabled(.selectAll, context: visible))
    }
}
