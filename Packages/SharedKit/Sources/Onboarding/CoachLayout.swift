import Foundation

/// The visual form the menu-bar coach takes.
///
/// The coach points at the menu-bar icon, so it can only exist when the menu bar
/// has room for it. When it does not, the form degrades rather than disappearing:
/// a first-run user who sees nothing has no way to learn the app is running.
public enum CoachLayout: Equatable, Sendable {
    /// L0: the full 288×96 panel with a pointer triangle.
    case full
    /// L1: a 240×64 single-line strip pinned below the menu bar.
    case compact
    /// L2: a 320×120 card centered on screen, with no pointer.
    case centeredCard
    /// L3: no panel at all; announce through accessibility only.
    case announcement
}

/// Chooses the coach form from the space actually available.
///
/// Kept free of AppKit types so the four levels are unit-testable without a
/// display. Sizes include the margin the panel needs from the screen edge and
/// from the menu bar; callers pass the screen's usable area below the menu bar.
public enum CoachLayoutResolver {
    /// Minimum usable width for the full panel, including margins.
    public static let fullMinimumWidth = 320.0
    /// Minimum usable height for the full panel, including margins.
    public static let fullMinimumHeight = 140.0
    /// Minimum usable width for the compact strip, including margins.
    public static let compactMinimumWidth = 272.0
    /// Minimum usable height for the compact strip, including margins.
    public static let compactMinimumHeight = 104.0
    /// Minimum usable width for the centered card, including margins.
    ///
    /// Must stay below `compactMinimumWidth`: the card is the fallback for when
    /// the compact strip does not fit, so a larger minimum would make it
    /// unreachable.
    public static let cardMinimumWidth = 260.0
    /// Minimum usable height for the centered card, including margins.
    public static let cardMinimumHeight = 80.0

    /// Picks the strongest form that fits.
    ///
    /// - Parameters:
    ///   - width: Usable width on the target screen, in points.
    ///   - height: Usable height below the menu bar, in points.
    /// - Returns: The first form whose minimum area fits, or `.announcement`
    ///   when nothing does. Non-finite or non-positive input is treated as
    ///   "no space" rather than as unlimited space.
    public static func resolve(width: Double, height: Double) -> CoachLayout {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return .announcement
        }
        if width >= fullMinimumWidth, height >= fullMinimumHeight {
            return .full
        }
        if width >= compactMinimumWidth, height >= compactMinimumHeight {
            return .compact
        }
        if width >= cardMinimumWidth, height >= cardMinimumHeight {
            return .centeredCard
        }
        return .announcement
    }
}
