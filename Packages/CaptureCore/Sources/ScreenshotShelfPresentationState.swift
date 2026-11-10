/// The capture activities that temporarily suppress the screenshot shelf panel.
public enum ScreenshotShelfSuppression: Hashable, Sendable {
    /// Suppress the shelf while SnapGlass captures the display.
    case capture
    /// Suppress the shelf while screen recording is active.
    case recording
    /// Suppress the shelf while another app occupies the display full-screen.
    case fullScreen
}

/// Tracks shelf show intent separately from temporary panel suppressions.
public struct ScreenshotShelfPresentationState: Equatable, Sendable {
    private var hasShowIntent = false
    private var activeSuppressions: Set<ScreenshotShelfSuppression> = []
    private var isScreenLocked = false

    /// Creates presentation state with no show intent or active suppressions.
    public init() {}

    /// Whether current show intent permits presenting the shelf panel.
    public var shouldPresentPanel: Bool {
        hasShowIntent && activeSuppressions.isEmpty && !isScreenLocked
    }

    /// Records a successful capture as a new intent to show the shelf.
    public mutating func captureCompleted() {
        guard !isScreenLocked else { return }
        hasShowIntent = true
    }

    /// Requests that the shelf be shown unless the screen is locked.
    public mutating func show() {
        guard !isScreenLocked else { return }
        hasShowIntent = true
    }

    /// Clears show intent until an explicit show or a later successful capture.
    public mutating func hide() {
        hasShowIntent = false
    }

    /// Begins a temporary suppression without changing show intent.
    ///
    /// - Parameter reason: The activity that currently suppresses the panel.
    public mutating func beginSuppression(_ reason: ScreenshotShelfSuppression) {
        activeSuppressions.insert(reason)
    }

    /// Ends a temporary suppression without changing show intent.
    ///
    /// - Parameter reason: The activity whose suppression has ended.
    public mutating func endSuppression(_ reason: ScreenshotShelfSuppression) {
        activeSuppressions.remove(reason)
    }

    /// Updates lock state; locking clears show intent so unlocking cannot re-expose the panel.
    ///
    /// - Parameter isLocked: Whether the screen is currently locked.
    public mutating func setScreenLocked(_ isLocked: Bool) {
        isScreenLocked = isLocked
        if isLocked {
            hasShowIntent = false
        }
    }
}
