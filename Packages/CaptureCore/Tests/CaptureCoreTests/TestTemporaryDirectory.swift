import Foundation

/// Test roots must live outside `/var`.
///
/// `RecordingLedgerFileSystem` rejects symlinked path components, and on macOS
/// `/var` is a symlink to `/private/var` while `standardizedFileURL` rewrites
/// `/private/var` back to `/var`. Both directions fail its path guards, so build
/// roots under the user caches directory instead of the temporary directory.
enum TestTemporaryDirectory {
    static func root(_ name: String) -> URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return
            base
            .appendingPathComponent("SnapGlassTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}
