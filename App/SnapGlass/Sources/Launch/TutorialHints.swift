import Combine
import Foundation
import SharedKit

/// Which in-place tutorial hint the editor or the shelf should show.
///
/// T2 and T3 are not panels. The editor banner and the shelf strip are drawn *by*
/// the surface they explain, so the explanation and the thing explained are in the
/// same place; a floating panel would cover the very region it describes.
public enum TutorialHint: Equatable, Sendable {
    /// The editor should show its bottom banner.
    case editor
    /// The shelf should show its top strip.
    case shelf
}

/// Publishes the tutorial hint the surfaces should draw.
///
/// Shared rather than injected everywhere because the shelf is built inside
/// `ScreenshotShelfPanel`, which has no view environment of its own. The state is
/// derived from persisted onboarding progress, never stored here, so a restart
/// resumes at the right step.
@MainActor
final class TutorialHints: ObservableObject {
    /// The process-wide instance the shelf and editor read.
    static let shared = TutorialHints()

    /// The hint to draw right now, or `nil`.
    @Published private(set) var activeHint: TutorialHint?

    private let defaults: UserDefaults

    /// Creates a hints publisher.
    ///
    /// - Parameter defaults: The domain holding `onboarding_tutorialStep`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    /// Re-reads persisted progress and updates the published hint.
    func refresh() {
        let step = TutorialStep.clamped(defaults.integer(forKey: PreferenceKeys.onboardingTutorialStep))
        let completed = defaults.double(forKey: PreferenceKeys.onboardingTutorialCompletedAt) > 0

        guard !completed else {
            activeHint = nil
            return
        }

        switch step {
        case .editorHint:
            activeHint = .editor
        case .shelfDrag:
            activeHint = .shelf
        case .none, .pressShortcut:
            activeHint = nil
        }
    }

    /// Records that the editor banner was handled, moving on to the shelf step.
    func completeEditorHint() {
        guard activeHint == .editor else { return }
        defaults.set(TutorialStep.shelfDrag.rawValue, forKey: PreferenceKeys.onboardingTutorialStep)
        activeHint = .shelf
    }

    /// Records that the shelf strip was handled, finishing the tutorial.
    func completeShelfHint() {
        guard activeHint == .shelf else { return }
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: PreferenceKeys.onboardingTutorialCompletedAt
        )
        defaults.set(TutorialStep.shelfDrag.rawValue, forKey: PreferenceKeys.onboardingTutorialStep)
        activeHint = nil
    }
}
