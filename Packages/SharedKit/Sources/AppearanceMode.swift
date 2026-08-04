import Foundation

/// User-selectable appearance modes shared across SnapGlass windows.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    /// Uses the current macOS appearance.
    case system
    /// Always renders using the light appearance.
    case light
    /// Always renders using the dark appearance.
    case dark

    /// Stable identity used by SwiftUI collections and pickers.
    public var id: String { rawValue }
}
