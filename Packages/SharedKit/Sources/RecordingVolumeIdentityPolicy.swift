import Foundation

/// Shared, read-only volume identity checks for a user-selected destination.
///
/// The persistent identity is `URLResourceValues.volumeUUIDString`; it survives
/// restarts, unlike `volumeIdentifier` or a device number. The `/Volumes`
/// compatibility guard only applies when no UUID was captured for an existing
/// setting, and only to the reserved mount-point namespace.
public enum RecordingVolumeIdentityPolicy {
    /// Reads the persistent UUID of the volume containing `directory`.
    ///
    /// - Parameter directory: An existing file or directory on the volume.
    /// - Returns: The persistent UUID, or `nil` when the volume does not report one.
    public static func volumeUUIDString(for directory: URL) -> String? {
        (try? directory.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Returns `true` for a `/Volumes/<Name>` path that resolves to the same
    /// volume as `/Volumes` through a real directory rather than a symlink.
    ///
    /// This is the compatibility guard for settings created before volume UUIDs
    /// were stored. Comparing against `/Volumes` (not `/`) avoids the APFS
    /// System/Data volume split. Symlinked system-volume aliases such as
    /// `/Volumes/Macintosh HD`, real mounted volumes, and paths outside
    /// `/Volumes` are not rejected by this check.
    ///
    /// - Parameter directory: The exact custom destination to classify.
    /// - Returns: `true` when the path looks like a stale mount point on the
    ///   volume that owns `/Volumes`.
    public static func isStaleVolumesMountPoint(_ directory: URL) -> Bool {
        let components = directory.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }

        let mountPoint = URL(
            fileURLWithPath: "/Volumes/\(components[2])",
            isDirectory: true
        )
        let isSymlink = (try? FileManager.default.destinationOfSymbolicLink(
            atPath: mountPoint.path
        )) != nil
        if isSymlink { return false }

        guard let current = volumeUUIDString(for: directory),
              let volumesRoot = volumeUUIDString(
                  for: URL(fileURLWithPath: "/Volumes", isDirectory: true)
              ) else {
            return false
        }
        return current == volumesRoot
    }
}
