import Foundation

/// Maps current recording capabilities to the existing screen-recording action.
public struct ScreenRecordingPipelineDecision: Sendable, Hashable {
    /// The screen-recording operation selected by the app adapter.
    public enum Action: Sendable, Hashable {
        /// Start a new screen-recording session.
        case start
        /// Stop and save the active screen-recording session.
        case stop
        /// Retry publication of a retained screen-recording result.
        case retry
        /// Resolve the active session as part of application termination.
        case quit
    }

    /// Selects the only valid operation, preferring termination and active work.
    public static func action(
        canStart: Bool,
        canStop: Bool,
        canRetry: Bool,
        isQuitting: Bool
    ) -> Action {
        if isQuitting { return .quit }
        if canStop { return .stop }
        if canRetry { return .retry }
        _ = canStart
        return .start
    }
}
