import AppKit
import Testing

@MainActor
struct RecordingWindowExclusionRegistryTests {
    @Test func registeringAndClosingWindowPublishesLiveWindowSet() {
        let registry = RecordingWindowExclusionRegistry()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var changes: [Set<CGWindowID>] = []
        registry.onChange = { changes.append($0) }

        registry.register(window)
        registry.unregister(CGWindowID(window.windowNumber))

        #expect(registry.currentWindowIDs.isEmpty)
        #expect(changes.last == Set<CGWindowID>())
        window.close()
    }
}
