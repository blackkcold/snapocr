import Darwin
import Foundation

/// Errors raised while reserving or publishing a recording output file.
public enum RecordingOutputTransactionError: Error, Equatable, LocalizedError, Sendable {
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
    /// The destination supports neither hard-link nor exclusive-rename publication.
    case unsupportedDestination
    /// The final filename was claimed by another transaction before publication.
    case destinationAlreadyExists
    /// The partial file could not be published without overwriting a destination.
    case publicationFailed

    /// English fallback description for atomic-publication failures.
    public var errorDescription: String? {
        switch self {
        case .unsupportedDestination:
            "This destination does not support safe recording publication. Choose another destination."
        case .destinationAlreadyExists:
            "A recording with this name already exists. The existing file was not changed."
        case .publicationFailed:
            "The recording could not be published without overwriting an existing file."
        case .invalidDestinationDirectory, .unableToReservePartialFile, .invalidState,
             .partialFileMissing, .writerNotFinished:
            nil
        }
    }
}

enum AtomicFileOperationResult: Equatable {
    case succeeded
    case destinationExists
    case unsupported
    case failed
}

enum RecordingOutputPublicationMethod: Equatable {
    case hardLink
    case exclusiveRename
}

struct AtomicRecordingOutputPublisher {
    private let hardLinkOperation: (URL, URL) -> AtomicFileOperationResult
    private let exclusiveRenameSupported: (URL) -> Bool
    private let exclusiveRenameOperation: (URL, URL) -> AtomicFileOperationResult

    init(
        hardLinkOperation: @escaping (URL, URL) -> AtomicFileOperationResult = Self.createHardLink,
        exclusiveRenameSupported: @escaping (URL) -> Bool = Self.supportsExclusiveRename,
        exclusiveRenameOperation: @escaping (URL, URL) -> AtomicFileOperationResult = Self.renameExclusively
    ) {
        self.hardLinkOperation = hardLinkOperation
        self.exclusiveRenameSupported = exclusiveRenameSupported
        self.exclusiveRenameOperation = exclusiveRenameOperation
    }

    func publish(partialURL: URL, finalURL: URL) throws -> RecordingOutputPublicationMethod {
        let hardLinkResult = hardLinkOperation(partialURL, finalURL)
        switch hardLinkResult {
        case .succeeded:
            return .hardLink
        case .destinationExists:
            throw RecordingOutputTransactionError.destinationAlreadyExists
        case .unsupported, .failed:
            break
        }

        let destinationDirectory = finalURL.deletingLastPathComponent()
        guard exclusiveRenameSupported(destinationDirectory) else {
            if hardLinkResult == .unsupported {
                throw RecordingOutputTransactionError.unsupportedDestination
            }
            throw RecordingOutputTransactionError.publicationFailed
        }

        switch exclusiveRenameOperation(partialURL, finalURL) {
        case .succeeded:
            return .exclusiveRename
        case .destinationExists:
            throw RecordingOutputTransactionError.destinationAlreadyExists
        case .unsupported:
            if hardLinkResult == .unsupported {
                throw RecordingOutputTransactionError.unsupportedDestination
            }
            throw RecordingOutputTransactionError.publicationFailed
        case .failed:
            throw RecordingOutputTransactionError.publicationFailed
        }
    }

    private static func createHardLink(from sourceURL: URL, to destinationURL: URL) -> AtomicFileOperationResult {
        let (status, errorCode) = withFileSystemPaths(sourceURL, destinationURL) { source, destination in
            let result = Darwin.link(source, destination)
            return (result, result == 0 ? 0 : errno)
        }
        return classify(status: status, errorCode: errorCode)
    }

    private static func supportsExclusiveRename(_ directoryURL: URL) -> Bool {
        var requestedAttributes = attrlist()
        requestedAttributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        requestedAttributes.volattr = attrgroup_t(ATTR_VOL_CAPABILITIES)

        var volumeAttributes = VolumeCapabilitiesBuffer()
        let result = directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return withUnsafeMutableBytes(of: &volumeAttributes) { buffer in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return getattrlist(
                    path,
                    &requestedAttributes,
                    baseAddress,
                    buffer.count,
                    UInt32(FSOPT_NOFOLLOW)
                )
            }
        }
        guard result == 0 else { return false }

        let exclusiveRenameCapability = UInt32(VOL_CAP_INT_RENAME_EXCL)
        return volumeAttributes.attributes.valid.1 & exclusiveRenameCapability != 0
            && volumeAttributes.attributes.capabilities.1 & exclusiveRenameCapability != 0
    }

    private static func renameExclusively(from sourceURL: URL, to destinationURL: URL) -> AtomicFileOperationResult {
        let (status, errorCode) = withFileSystemPaths(sourceURL, destinationURL) { source, destination in
            let result = renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL))
            return (result, result == 0 ? 0 : errno)
        }
        return classify(status: status, errorCode: errorCode)
    }

    private static func withFileSystemPaths(
        _ sourceURL: URL,
        _ destinationURL: URL,
        operation: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> (Int32, Int32)
    ) -> (Int32, Int32) {
        sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            guard let sourcePath else { return (-1, EINVAL) }
            return destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let destinationPath else { return (-1, EINVAL) }
                return operation(sourcePath, destinationPath)
            }
        }
    }

    private static func classify(status: Int32, errorCode: Int32) -> AtomicFileOperationResult {
        guard status != 0 else { return .succeeded }
        if errorCode == EEXIST { return .destinationExists }
        if errorCode == EOPNOTSUPP || errorCode == ENOTSUP || errorCode == ENOSYS
            || errorCode == EXDEV || errorCode == EPERM || errorCode == EINVAL {
            return .unsupported
        }
        return .failed
    }
}

private struct VolumeCapabilitiesBuffer {
    var length: UInt32 = 0
    var attributes = vol_capabilities_attr_t()
}

/// Reserves a unique hidden MP4 partial and publishes it without overwriting files.
public final class RecordingOutputTransaction {
    private enum State {
        case reserved
        case writing
        case finished
        case published
        case discarded
    }

    /// Hidden same-directory URL supplied to the media writer.
    public let partialURL: URL
    /// Unique user-visible MP4 destination.
    public let finalURL: URL

    private let fileManager: FileManager
    private let publisher: AtomicRecordingOutputPublisher
    private var state = State.reserved

    /// Whether the writer finished and the partial file is still on disk, so publication can be retried.
    public var isPublishable: Bool {
        state == .finished && fileManager.fileExists(atPath: partialURL.path)
    }

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
    public convenience init(
        destinationDirectory: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            destinationDirectory: destinationDirectory,
            now: now,
            timeZone: timeZone,
            fileManager: fileManager,
            identifierProvider: UUID.init,
            publisher: AtomicRecordingOutputPublisher()
        )
    }

    init(
        destinationDirectory: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default,
        identifierProvider: @escaping () -> UUID,
        publisher: AtomicRecordingOutputPublisher
    ) throws {
        self.fileManager = fileManager
        self.publisher = publisher
        let urls = try Self.reserveURLs(
            in: destinationDirectory,
            now: now,
            timeZone: timeZone,
            fileManager: fileManager,
            identifierProvider: identifierProvider
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

    /// Deletes the unpublished partial owned by this transaction.
    func discardPartial() throws {
        switch state {
        case .reserved, .writing, .finished:
            break
        case .discarded:
            return
        case .published:
            throw RecordingOutputTransactionError.invalidState
        }

        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }
        state = .discarded
    }

    /// Publishes the finished MP4 through a hard link or exclusive rename.
    ///
    /// If publication fails, the `partialURL` remains available.
    ///
    /// - Returns: The final recording URL.
    /// - Throws: `RecordingOutputTransactionError` if the writer is unfinished,
    ///   the partial is missing, or the destination cannot be published atomically without replacement.
    public func publish() throws -> URL {
        guard state == .finished else { throw RecordingOutputTransactionError.writerNotFinished }
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw RecordingOutputTransactionError.partialFileMissing
        }

        let method = try publisher.publish(partialURL: partialURL, finalURL: finalURL)

        state = .published
        if method == .hardLink {
            try? fileManager.removeItem(at: partialURL)
        }
        return finalURL
    }

    private static func reserveURLs(
        in directory: URL,
        now: Date,
        timeZone: TimeZone,
        fileManager: FileManager,
        identifierProvider: () -> UUID
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
            guard !fileManager.fileExists(atPath: final.path) else {
                suffix = (suffix ?? 1) + 1
                continue
            }

            let partial = directory.appendingPathComponent(
                ".SnapGlass-\(identifierProvider().uuidString).mp4.partial"
            )
            switch createExclusivePartial(at: partial) {
            case .created:
                return (partial, final)
            case .alreadyExists:
                continue
            case .failed:
                throw RecordingOutputTransactionError.unableToReservePartialFile
            }
        }
    }

    private static func createExclusivePartial(at url: URL) -> ExclusivePartialCreationResult {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .failed }
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            guard descriptor >= 0 else {
                return errno == EEXIST ? .alreadyExists : .failed
            }
            guard Darwin.close(descriptor) == 0 else {
                _ = Darwin.unlink(path)
                return .failed
            }
            return .created
        }
    }
}

private enum ExclusivePartialCreationResult {
    case created
    case alreadyExists
    case failed
}
