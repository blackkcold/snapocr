import Foundation

/// Errors raised while reserving or publishing a recording output file.
public enum RecordingOutputTransactionError: Error, Equatable, Sendable {
    /// The destination does not exist or is not a directory.
    case invalidDestinationDirectory
    /// A unique hidden partial file could not be reserved.
    case unableToReservePartialFile
    /// The requested operation is invalid for the current transaction phase.
    case invalidState
    /// The partial file is missing.
    case partialFileMissing
    /// The writer has not successfully finished.
    case writerNotFinished
    /// The partial file could not be published without overwriting a destination.
    case publicationFailed
}

/// Reserves a unique hidden MP4 partial and publishes it without overwriting files.
public final class RecordingOutputTransaction {
    private enum State {
        case reserved
        case writing
        case finished
        case published
    }

    /// Hidden same-directory URL supplied to the media writer.
    public let partialURL: URL
    /// Unique user-visible MP4 destination.
    public let finalURL: URL

    private let fileManager: FileManager
    private var state = State.reserved

    /// Reserves a hidden partial file and a unique final filename.
    ///
    /// The destination directory must already exist. The first final name is
    /// `SnapGlass_yyyy-MM-dd_HH-mm-ss.mp4`; collisions receive a numeric suffix.
    ///
    /// - Parameters:
    ///   - destinationDirectory: Existing directory selected for the recording.
    ///   - now: Timestamp used to construct the filename; defaults to the current time.
    ///   - timeZone: Time zone used in the filename; defaults to the current zone.
    ///   - fileManager: File manager used for filesystem operations.
    /// - Throws: `RecordingOutputTransactionError` if the directory or reservation is invalid.
    public init(
        destinationDirectory: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let urls = try Self.reserveURLs(
            in: destinationDirectory,
            now: now,
            timeZone: timeZone,
            fileManager: fileManager
        )
        partialURL = urls.partial
        finalURL = urls.final
    }

    /// Removes the zero-byte reservation immediately before creating the writer.
    ///
    /// AVAssetWriter creates its output file at this URL. The transaction keeps
    /// ownership of the reserved name while the writer is active.
    public func prepareForWriting() throws {
        guard state == .reserved else { throw RecordingOutputTransactionError.invalidState }
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw RecordingOutputTransactionError.partialFileMissing
        }
        try fileManager.removeItem(at: partialURL)
        state = .writing
    }

    /// Records successful writer finalization before the output can be published.
    public func markWriterFinished() throws {
        guard state == .writing else { throw RecordingOutputTransactionError.invalidState }
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw RecordingOutputTransactionError.partialFileMissing
        }
        state = .finished
    }

    /// Publishes the finished MP4 without replacing an existing destination.
    ///
    /// If publication fails, `partialURL` remains available for recovery.
    ///
    /// - Returns: The final recording URL.
    /// - Throws: `RecordingOutputTransactionError` if the writer is unfinished,
    ///   the partial is missing, or the final path cannot be created exclusively.
    public func publish() throws -> URL {
        guard state == .finished else { throw RecordingOutputTransactionError.writerNotFinished }
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw RecordingOutputTransactionError.partialFileMissing
        }

        do {
            try fileManager.linkItem(at: partialURL, to: finalURL)
        } catch {
            throw RecordingOutputTransactionError.publicationFailed
        }

        state = .published
        try? fileManager.removeItem(at: partialURL)
        return finalURL
    }

    private static func reserveURLs(
        in directory: URL,
        now: Date,
        timeZone: TimeZone,
        fileManager: FileManager
    ) throws -> (partial: URL, final: URL) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RecordingOutputTransactionError.invalidDestinationDirectory
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: now)

        var suffix: Int?
        while true {
            let suffixText = suffix.map { "_\($0)" } ?? ""
            let baseName = "SnapGlass_\(timestamp)\(suffixText)"
            let final = directory.appendingPathComponent("\(baseName).mp4")
            let partial = directory.appendingPathComponent(".\(baseName).mp4.partial")
            guard !fileManager.fileExists(atPath: final.path),
                  !fileManager.fileExists(atPath: partial.path) else {
                suffix = (suffix ?? 1) + 1
                continue
            }

            let created = fileManager.createFile(
                atPath: partial.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
            guard created else { throw RecordingOutputTransactionError.unableToReservePartialFile }
            return (partial, final)
        }
    }
}
