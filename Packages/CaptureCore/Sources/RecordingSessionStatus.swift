import Foundation

/// UI-facing phase of the screen-recording session.
///
/// This lives in `CaptureCore` so the menu-bar presentation and the quit flow can share one
/// status type without pulling AppKit into the core state machine.
public enum RecordingSessionStatus: Equatable, Sendable {
    case idle
    case selectingSource
    case countdown(Int)
    case starting
    case recording
    case saving

    public var isBusy: Bool { self != .idle }

    public var needsQuitConfirmation: Bool {
        switch self {
        case .starting, .recording, .saving: true
        case .idle, .selectingSource, .countdown: false
        }
    }
}

/// The compact state a menu-bar recording indicator can show.
///
/// Kept separate from `RecordingSessionStatus` because the menu bar also has to represent an
/// area capture, and because `.selectingSource`, `.countdown`, and `.starting` should all read as
/// "preparing" without a red recording dot.
public enum RecordingMenuBarIndicator: Equatable, Sendable, CaseIterable {
    case camera
    case capturing
    case preparing
    case recording
    case saving
    case failed

    /// SF Symbol used by the menu-bar label. Kept here so every indicator has one testable name.
    public var systemImage: String {
        switch self {
        case .camera:
            "camera.viewfinder"
        case .capturing:
            "viewfinder.circle.fill"
        case .preparing:
            "record.circle"
        case .recording:
            "record.circle.fill"
        case .saving:
            "arrow.down.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    /// A red dot is only meaningful while the stream is actually recording.
    public var showsRecordingDot: Bool {
        self == .recording
    }
}

public extension RecordingSessionStatus {
    /// Resolves the menu-bar indicator, giving an in-progress area capture precedence.
    ///
    /// - Parameters:
    ///   - isCapturing: Whether an area capture is currently in progress.
    ///   - hasFailure: Whether a failed recording is still awaiting the user's attention.
    func menuBarIndicator(isCapturing: Bool, hasFailure: Bool = false) -> RecordingMenuBarIndicator {
        if isCapturing { return .capturing }
        if hasFailure { return .failed }
        switch self {
        case .idle:
            return .camera
        case .selectingSource, .countdown, .starting:
            return .preparing
        case .recording:
            return .recording
        case .saving:
            return .saving
        }
    }
}
