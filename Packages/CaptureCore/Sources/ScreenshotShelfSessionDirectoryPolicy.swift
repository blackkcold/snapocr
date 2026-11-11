import Darwin
import Foundation

/// Decides whether a screenshot-shelf session directory may be removed.
///
/// The encrypted session store and the plaintext drag-export store each create one
/// directory per process. A second running instance (a debug build, a second copy, or
/// any other process that boots the shelf) must never delete the directory of a process
/// that is still alive: doing so removes the originals and exported files the running
/// app is using for drag-and-drop, and the app cannot recover until it restarts.
///
/// Directory names therefore carry the owning process id. Live owners are never swept;
/// dead owners are swept after a grace period. Legacy directories without an owner id are
/// kept for a longer grace period so an older build that is still running is not disturbed.
public enum ScreenshotShelfSessionDirectoryPolicy {
    /// Every session directory created by the shelf starts with this prefix.
    public static let directoryPrefix = "session-"

    /// Builds a session directory name that carries the owning process id.
    public static func directoryName(ownerPID: Int32, sessionID: UUID) -> String {
        "\(directoryPrefix)\(max(0, ownerPID))-\(sessionID.uuidString)"
    }

    /// Extracts the owner process id from a directory name.
    ///
    /// Returns `nil` for the legacy `session-<uuid>` shape, which has no owner information.
    public static func ownerPID(fromDirectoryName name: String) -> Int32? {
        guard name.hasPrefix(directoryPrefix) else { return nil }
        let remainder = name.dropFirst(directoryPrefix.count)
        guard let separator = remainder.firstIndex(of: "-") else { return nil }
        let token = remainder[..<separator]
        guard !token.isEmpty,
              token.allSatisfy({ $0.isNumber }),
              let pid = Int32(token),
              pid > 0 else { return nil }
        return pid
    }

    /// Whether a process with `pid` is still running.
    ///
    /// `EPERM` means the process exists but is owned by another user, so it counts as alive.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Whether a foreign session directory is stale enough to remove.
    ///
    /// - Parameters:
    ///   - directoryName: The directory's last path component.
    ///   - modifiedAt: The directory's content modification date.
    ///   - now: Current time, injectable for tests.
    ///   - grace: Age a dead owner's directory must reach before removal.
    ///   - legacyGrace: Age a legacy (owner-less) directory must reach before removal.
    /// - Returns: `true` only when the directory belongs to a dead process and is old
    ///   enough, or is a legacy directory older than `legacyGrace`.
    public static func shouldSweep(
        directoryName: String,
        modifiedAt: Date,
        now: Date,
        grace: TimeInterval,
        legacyGrace: TimeInterval
    ) -> Bool {
        guard directoryName.hasPrefix(directoryPrefix) else { return false }
        let age = now.timeIntervalSince(modifiedAt)
        if let ownerPID = ownerPID(fromDirectoryName: directoryName) {
            guard !isProcessAlive(ownerPID) else { return false }
            return age >= max(0, grace)
        }
        return age >= max(0, legacyGrace)
    }
}
