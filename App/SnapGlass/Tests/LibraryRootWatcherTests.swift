import Foundation
import Testing

/// Regression coverage for the crash on library-window close.
///
/// The watcher's dispatch handlers run on its own background queue. When they were
/// built inside a `@MainActor` method they inherited main-actor isolation, and
/// Swift 6's executor assertion killed the process on cancellation. The sleeps are
/// the point: cancel handlers run asynchronously, so a test that returned right
/// after `stop()` would pass even with the bug present.
@MainActor
struct LibraryRootWatcherTests {
    @Test func startAndStopDoNotTrap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = LibraryRootWatcher()

        watcher.start(roots: [root])
        try await Task.sleep(for: .milliseconds(120))
        watcher.stop()
        // Let the cancel handlers run on the watcher's queue before moving on.
        try await Task.sleep(for: .milliseconds(250))

        // Cancel-then-restart is the second half of the original crash path.
        watcher.start(roots: [root])
        try await Task.sleep(for: .milliseconds(120))
        watcher.stop()
        try await Task.sleep(for: .milliseconds(250))
    }
}
