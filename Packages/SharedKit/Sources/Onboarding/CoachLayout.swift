import CoreGraphics
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

public extension CoachLayout {
    /// The form's nominal size, in points.
    ///
    /// The height is a floor, not a ceiling: the tutorial variant adds a "Try it"
    /// row and some translations wrap one line further, so the rendered height
    /// has to be measured rather than assumed.
    var designSize: CGSize {
        switch self {
        case .full: CGSize(width: 288, height: 96)
        case .compact: CGSize(width: 240, height: 64)
        case .centeredCard: CGSize(width: 320, height: 120)
        case .announcement: CGSize(width: 1, height: 1)
        }
    }
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

    /// Gap between the panel and the right screen edge.
    public static let panelTrailingInset = 12.0
    /// Gap between the panel and the menu bar.
    public static let panelTopInset = 8.0
    /// Gap between the panel and the bottom of the usable area.
    public static let panelBottomInset = 12.0

    /// Fits the panel to the space a screen can actually give it.
    ///
    /// Without an upper bound the panel's height came from SwiftUI's minimum
    /// size, which is computed at width zero: the 49-character English subtitle
    /// reported 574pt and AppKit stretched a 288×96 panel to 288×888, past the
    /// bottom of a 1280×800 display.
    ///
    /// - Parameters:
    ///   - design: The form's nominal size.
    ///   - measuredHeight: The height the content renders at the design width.
    ///   - available: The screen's usable area below the menu bar.
    /// - Returns: A size that fits `available`, keeping `design.height` as the
    ///   floor; when the screen is smaller than the design, the screen wins.
    ///   Degenerate input yields a 1×1 size so no caller can build a panel with
    ///   no bound at all.
    public static func panelSize(
        design: CGSize,
        measuredHeight: Double,
        available: CGSize
    ) -> CGSize {
        guard
            available.width.isFinite, available.height.isFinite,
            available.width > 0, available.height > 0,
            design.width.isFinite, design.height.isFinite,
            design.width > 0, design.height > 0,
            measuredHeight.isFinite, measuredHeight > 0
        else { return CGSize(width: 1, height: 1) }

        let width = min(design.width, max(1, available.width - panelTrailingInset * 2))
        let ceiling = max(1, available.height - panelTopInset - panelBottomInset)
        let height = max(min(design.height, ceiling), min(measuredHeight, ceiling))
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    /// Places a sized panel inside the usable area.
    ///
    /// - Parameters:
    ///   - layout: The chosen form.
    ///   - size: A size from `panelSize(design:measuredHeight:available:)`.
    ///   - visible: The screen's usable area below the menu bar.
    /// - Returns: A frame fully inside `visible`; `.zero` when there is no room.
    public static func panelFrame(
        layout: CoachLayout,
        size: CGSize,
        visible: CGRect
    ) -> CGRect {
        guard
            layout != .announcement,
            visible.origin.x.isFinite, visible.origin.y.isFinite,
            visible.width.isFinite, visible.height.isFinite,
            visible.width > 0, visible.height > 0,
            size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0
        else { return .zero }

        let originX: CGFloat
        let originY: CGFloat
        switch layout {
        case .full, .compact:
            // Right-aligned: new menu-bar items land near the right end, so that is
            // where the pointer and the copy both point. Clamped so a narrow
            // display pushes the panel inward instead of off screen.
            originX = max(visible.minX, visible.maxX - size.width - panelTrailingInset)
            originY = max(
                visible.minY + panelBottomInset,
                visible.maxY - size.height - panelTopInset
            )
        case .centeredCard:
            originX = min(
                max(visible.midX - size.width / 2, visible.minX),
                visible.maxX - size.width
            )
            originY = min(
                max(visible.midY - size.height / 2, visible.minY + panelBottomInset),
                visible.maxY - size.height - panelTopInset
            )
        case .announcement:
            return .zero
        }
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}
