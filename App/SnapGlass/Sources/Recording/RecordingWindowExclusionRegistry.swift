import AppKit

/// Tracks app-owned windows that must stay out of a display or region recording.
@MainActor
public final class RecordingWindowExclusionRegistry {
    public static let shared = RecordingWindowExclusionRegistry()

    private var windowIDs: Set<CGWindowID> = []
    private var closeObservers: [CGWindowID: NSObjectProtocol] = [:]

    /// Receives the complete live exclusion set after a window is added or removed.
    public var onChange: (Set<CGWindowID>) -> Void = { _ in }

    public init() {}

    public var currentWindowIDs: Set<CGWindowID> { windowIDs }

    public func register(_ window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        let windowID = CGWindowID(window.windowNumber)
        guard windowIDs.insert(windowID).inserted else { return }

        closeObservers[windowID] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.unregister(windowID)
            }
        }
        onChange(windowIDs)
    }

    public func unregister(_ windowID: CGWindowID) {
        guard windowIDs.remove(windowID) != nil else { return }
        if let observer = closeObservers.removeValue(forKey: windowID) {
            NotificationCenter.default.removeObserver(observer)
        }
        onChange(windowIDs)
    }
}
