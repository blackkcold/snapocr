import AppKit
import SharedKit
import SwiftUI

/// The rotating tip section inside the menu-bar menu.
///
/// Shown inline rather than as a panel: the user already opened the menu, so a
/// second floating surface would be one more thing to dismiss. The section never
/// disappears once tips run out — it keeps a permanent row that re-opens the guide,
/// so the menu's shape does not change as onboarding progresses.
struct MenuBarTipsSection: View {
    /// The tip to show, if one is due.
    let tip: OnboardingTip?
    /// Label for the `%@` some subtitles carry, such as the area-capture shortcut.
    let argument: String
    /// Called when the user acts on an actionable tip.
    let onAct: (OnboardingTip) -> Void
    /// Called when the user asks for the guide again.
    let onShowGuide: () -> Void

    var body: some View {
        if let tip {
            Button {
                onAct(tip)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(tip.titleKey))
                    Text(subtitle(for: tip))
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // A tip whose copy does not describe an immediate action must not be
            // clickable; see `OnboardingTips.record`.
            .disabled(!tip.isActionable)
        }

        Button(LocalizedStringKey("Show the welcome guide again")) {
            onShowGuide()
        }
    }

    /// Resolves the subtitle, filling in its placeholder when it has one.
    ///
    /// A `Text(LocalizedStringKey:)` cannot substitute `%@`; without this the menu
    /// would show the literal "Press %@ anywhere". The format string comes from the
    /// catalog already localized, so the placeholder position follows each language.
    ///
    /// - Parameter tip: The tip being shown.
    /// - Returns: The subtitle, with any placeholder replaced.
    private func subtitle(for tip: OnboardingTip) -> String {
        let localized = AppLocalization.string(tip.subtitleKey)
        guard localized.contains("%@") else { return localized }
        return String(format: localized, argument)
    }
}
