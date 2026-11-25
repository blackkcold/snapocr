import Foundation

/// Holds the one control panel a recording session may show at a time.
///
/// The panel is a borderless floating window that is never released when closed.
/// A panel that loses its owner therefore stays on screen forever: nothing else
/// holds a reference to dismiss it, and the session can only clean up whatever the
/// slot points at. Replacing the panel is the one place that can strand a window,
/// so replacements go through here and always retire what they replace.
@MainActor
enum RecordingHUDPanelSlot {
    /// Installs `panel` as the current one, dismissing the panel it replaces.
    ///
    /// Re-installing the same panel is a no-op: `present` is idempotent and the
    /// live panel must not be ordered out from under an in-flight update.
    static func install<Panel: AnyObject>(
        _ panel: Panel?,
        into current: inout Panel?,
        dismiss: (Panel) -> Void
    ) {
        guard current !== panel else { return }
        if let previous = current { dismiss(previous) }
        current = panel
    }
}
