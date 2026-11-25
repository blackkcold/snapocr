import Foundation

/// Pure keyboard-command table for the library.
///
/// The type is independent of SwiftUI so the headless test suite can exercise
/// the shortcut matrix and availability rules. `LibraryView` builds its hidden
/// shortcut buttons from `LibraryCommand.allCases`, so this table is the single
/// source of truth: a shortcut cannot drift from its tested mapping.
///
/// Arrow-key movement is not listed: the grid uses `ScrollView` and moving the
/// selection without scrolling it into view would be worse than no binding.
public enum LibraryCommand: String, CaseIterable, Sendable, Hashable {
    case preview
    case open
    case export
    case delete
    case favourite
    case selectAll
    case cancel

    /// Normalized key name, matching `command(for:modifiers:)`.
    public var key: String {
        switch self {
        case .preview: return "space"
        case .open: return "return"
        case .export: return "e"
        case .delete: return "delete"
        case .favourite: return "f"
        case .selectAll: return "a"
        case .cancel: return "escape"
        }
    }

    public var modifiers: Set<LibraryCommandModifier> {
        switch self {
        case .preview, .open, .cancel: return []
        case .export, .delete, .selectAll: return [.command]
        case .favourite: return [.command, .shift]
        }
    }

    /// Existing localization key used for the command's accessibility label.
    public var titleKey: String {
        switch self {
        case .preview: return "Quick Look"
        case .open: return "Open"
        case .export: return "Export…"
        case .delete: return "Delete…"
        case .favourite: return "Add favourite"
        case .selectAll: return "Select All"
        case .cancel: return "Cancel"
        }
    }
}

public enum LibraryCommandModifier: String, Sendable, Hashable {
    case command
    case shift
    case option
    case control
}

public struct LibraryCommandContext: Sendable, Equatable {
    public var hasSelection: Bool
    public var visibleItemCount: Int
    public var canOpen: Bool
    public var canExport: Bool
    public var canDelete: Bool
    public var canFavourite: Bool
    public var isSelecting: Bool
    public var isSheetPresented: Bool

    public init(
        hasSelection: Bool = false,
        visibleItemCount: Int = 0,
        canOpen: Bool = false,
        canExport: Bool = false,
        canDelete: Bool = false,
        canFavourite: Bool = false,
        isSelecting: Bool = false,
        isSheetPresented: Bool = false
    ) {
        self.hasSelection = hasSelection
        self.visibleItemCount = visibleItemCount
        self.canOpen = canOpen
        self.canExport = canExport
        self.canDelete = canDelete
        self.canFavourite = canFavourite
        self.isSelecting = isSelecting
        self.isSheetPresented = isSheetPresented
    }
}

public enum LibraryCommandRouter {
    /// Maps a key and modifier set to a command. Availability is decided by
    /// `isEnabled`, so the UI can keep a shortcut registered but disabled.
    public static func command(
        for key: String,
        modifiers: Set<LibraryCommandModifier>
    ) -> LibraryCommand? {
        let normalized = key.lowercased()
        return LibraryCommand.allCases.first {
            $0.key == normalized && $0.modifiers == modifiers
        }
    }

    public static func isEnabled(
        _ command: LibraryCommand,
        context: LibraryCommandContext
    ) -> Bool {
        // Modal sheets own the keyboard; the hidden bindings must stand down.
        guard !context.isSheetPresented else { return false }
        switch command {
        case .preview:
            return context.hasSelection
        case .open:
            return context.hasSelection && context.canOpen
        case .export:
            return context.canExport
        case .delete:
            return context.hasSelection && context.canDelete
        case .favourite:
            return context.hasSelection && context.canFavourite
        case .selectAll:
            return context.visibleItemCount > 0
        case .cancel:
            return context.isSelecting || context.hasSelection
        }
    }
}
