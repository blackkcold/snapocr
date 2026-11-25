import AppKit
import CaptureCore

/// Warms the AppKit/SwiftUI path the recording HUD uses after launch.
///
/// A process's first control-panel creation pays one-time framework loading
/// (SwiftUI hosting, system material, window-server registration). During a
/// recording that cost lands inside the first-visible measurement: a cold first
/// recording waited up to ~340 ms for a HUD that normally appears in ~20 ms.
/// Warming the real panel once after launch moves that work out of the user's
/// first recording without keeping a panel alive.
///
/// The panel is created, presented, and dismissed in one main-actor turn, so it
/// is never retained, never composited, and never touches session state.
@MainActor
enum RecordingHUDPrewarm {
    /// Default delay, long enough not to compete with launch itself.
    static let defaultDelay: Duration = .seconds(2)

    /// Schedules one warmup on the main actor.
    ///
    /// - Parameters:
    ///   - delay: How long to wait before warming; the default keeps launch smooth.
    ///   - shouldRun: Re-checked when the delay elapses; return `false` to skip.
    static func schedule(
        after delay: Duration = defaultDelay,
        shouldRun: @escaping @MainActor () -> Bool
    ) {
        Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard shouldRun() else { return }
            run()
        }
    }

    /// Creates the production panel once and dismisses it before returning.
    ///
    /// The presented state mirrors the first phase a start request shows, so the
    /// same view hierarchy and material are exercised. No panel is stored
    /// anywhere: the local reference is released when this function returns.
    static func run() {
        let panel = RecordingControlPanel(
            on: nil,
            corner: .bottomLeading,
            opacity: 1,
            hoverRestore: false,
            actions: RecordingControlPanelActions(
                onCancel: {},
                onStop: {},
                onRetry: {},
                onReveal: { _ in },
                onDismiss: {},
                onHideWhileSaving: {},
                onCornerChange: { _ in },
                onToggleAudioDetails: {},
                onPreview: {},
                onStopPreview: {},
                onOpenLatest: { _ in },
                onOpenRecordings: {},
                onJoinExport: {}
            )
        )
        panel.present(state: .starting(kind: .audio, phase: .startingAudioPipeline))
        panel.dismiss()
    }
}
