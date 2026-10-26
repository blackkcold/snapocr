import AppKit
import Foundation

// MARK: - EditableAnnotationCanvasNSView Tool Shortcuts

extension EditableAnnotationCanvasNSView {
    /// Single-key tool shortcuts, as in every annotation and design tool.
    ///
    /// Command/option/control combinations are left to the menu system so ⌘C,
    /// ⌘Z and friends keep working.
    ///
    /// - Returns: `true` when the event was consumed.
    func handleToolKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        guard !modifiers.contains(.command),
              !modifiers.contains(.option),
              !modifiers.contains(.control),
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        guard let tool = Self.toolShortcuts[characters] else { return false }
        onToolShortcut?(tool)
        return true
    }

    /// Key to tool mapping. Crop uses `c`, so ⌘C must stay a command combination.
    static let toolShortcuts: [String: EditorTool] = [
        "v": .select,
        "a": .arrow,
        "r": .rect,
        "t": .text,
        "p": .pen,
        "h": .highlight,
        "b": .blur,
        "c": .crop,
        "i": .picker,
    ]
}
