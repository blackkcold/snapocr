import AppKit
import Testing

@MainActor
struct RecordingWindowExclusionRegistryTests {
    /// xctest starts without an `NSApplication` instance, and a programmatically
    /// created `NSWindow` is released by `close()` unless told otherwise. Under ARC
    /// that second release crashes the test host, so both facts are fixed here.
    private func makeTestWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func registeringAndClosingWindowPublishesLiveWindowSet() {
        let registry = RecordingWindowExclusionRegistry()
        let window = makeTestWindow()
        var changes: [Set<CGWindowID>] = []
        registry.onChange = { changes.append($0) }

        registry.register(window)
        let windowID = CGWindowID(window.windowNumber)
        #expect(registry.currentWindowIDs == [windowID])

        window.close()

        #expect(registry.currentWindowIDs.isEmpty)
        #expect(changes == [[windowID], []])
    }

    @Test func unregisteringWindowPublishesEmptySet() {
        let registry = RecordingWindowExclusionRegistry()
        let window = makeTestWindow()
        var changes: [Set<CGWindowID>] = []
        registry.onChange = { changes.append($0) }

        registry.register(window)
        registry.unregister(CGWindowID(window.windowNumber))

        #expect(registry.currentWindowIDs.isEmpty)
        #expect(changes.last == Set<CGWindowID>())
        window.close()
    }
}
