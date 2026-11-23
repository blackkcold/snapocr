import Foundation
import SharedKit

/// Free-space thresholds and formatting shared by recording start/continue
/// checks and user-facing messages.
///
/// This lives outside `RecordingSessionController` so the editor/localization
/// test targets can compile the message helpers without pulling in the whole
/// recording pipeline.
enum RecordingStorage {
    static let minimumStartFreeSpace: Int64 = 1_024 * 1_024 * 1_024
    static let minimumContinueFreeSpace: Int64 = 512 * 1_024 * 1_024

    static func availableBytes(at directory: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let availableBytes = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return availableBytes.int64Value
    }

    static func formattedBytes(_ byteCount: Int64) -> String {
        let language = UserDefaults.standard.string(forKey: PreferenceKeys.appLanguage)
            ?? PreferenceDefaults.appLanguage
        return ByteCountFormatStyle(
            style: .file,
            locale: (AppLanguage(rawValue: language) ?? .system).locale
        ).format(byteCount)
    }
}
