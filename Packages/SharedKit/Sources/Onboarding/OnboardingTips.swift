import Foundation

/// One rotating menu-bar tip shown after onboarding is complete.
///
/// Each tip uses an existing localization key for its title so the
/// `Localizable.strings` files gain only a subtitle per tip. A tip whose text
/// promises an action must be able to perform it: `record` deliberately has no
/// action, because its copy says "audio and screen recording both start here"
/// and clicking it would begin an audio recording instead.
public struct OnboardingTip: Equatable, Identifiable, Sendable {
    /// Stable identifier persisted in the shown-tips list.
    public let id: String
    /// Localization key for the title; reused from the existing catalog.
    public let titleKey: String
    /// Localization key for the subtitle.
    public let subtitleKey: String
    /// Whether the row performs an action when clicked.
    public let isActionable: Bool

    /// Creates a tip.
    public init(id: String, titleKey: String, subtitleKey: String, isActionable: Bool) {
        self.id = id
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.isActionable = isActionable
    }
}

/// The ordered tips shown in the menu bar popover.
public enum OnboardingTips {
    /// Tip for area capture; actionable because the action is immediate and reversible.
    public static let area = OnboardingTip(
        id: "area",
        titleKey: "Area Capture",
        subtitleKey: "Press %@ anywhere to grab part of the screen.",
        isActionable: true
    )

    /// Tip for the screenshot shelf; actionable because opening it has no side effect.
    public static let shelf = OnboardingTip(
        id: "shelf",
        titleKey: "Screenshot Shelf",
        subtitleKey: "Your last screenshots wait in the shelf. Drag one straight into any app.",
        isActionable: true
    )

    /// Tip for recording; not actionable so the copy and the click stay consistent.
    public static let record = OnboardingTip(
        id: "record",
        titleKey: "Start Audio Recording",
        subtitleKey: "Recording audio and screen video both start here — pick the source first.",
        isActionable: false
    )

    /// Every tip in display order.
    public static let all: [OnboardingTip] = [area, shelf, record]

    /// The first tip not yet shown, or `nil` when all have been shown.
    ///
    /// - Parameter shownIDs: Identifiers already presented to this user.
    /// - Returns: The next tip in order, or `nil`.
    public static func next(shownIDs: Set<String>) -> OnboardingTip? {
        all.first { !shownIDs.contains($0.id) }
    }
}
