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

/// A validated description of one recording output segment.
///
/// The request owns naming and shape only. Creating a request does not inspect
/// the destination or touch the filesystem.
public struct RecordingOutputRequest: Equatable, Sendable {
    /// The kind of output produced by one recording segment.
    public enum Shape: Equatable, Sendable {
        /// A single file using the normalized lowercase extension, without a leading dot.
        case singleFile(fileExtension: String)
        /// A directory whose tracks and manifest are written and sealed by the recording layer.
        case directory
    }

    /// Existing directory that receives the segment output.
    public let destinationDirectory: URL
    /// Complete base name including any date prefix, without a segment suffix or extension.
    public let stem: String
    /// Non-negative zero-based segment index used in the output name.
    public let segmentIndex: Int
    /// Whether the segment publishes as a single file or as a directory.
    public let shape: Shape

    /// Creates a validated output request.
    ///
    /// - Parameters:
    ///   - destinationDirectory: Existing directory that receives the output.
    ///   - stem: Complete base name without a segment suffix or extension.
    ///   - segmentIndex: Zero-based segment index; must be non-negative.
    ///   - shape: Single-file output with an extension, or directory output.
    /// - Throws: `RecordingOutputRequestError` when the stem, index, or extension is invalid.
    public init(
        destinationDirectory: URL,
        stem: String,
        segmentIndex: Int,
        shape: Shape
    ) throws {
        guard !stem.isEmpty else { throw RecordingOutputRequestError.emptyStem }
        guard stem != ".", stem != "..", !stem.hasPrefix("."),
              !stem.contains("/"), !stem.contains("\\"), !stem.contains("\0")
        else {
            throw RecordingOutputRequestError.invalidStem
        }
        guard segmentIndex >= 0 else { throw RecordingOutputRequestError.negativeSegmentIndex }

        switch shape {
        case .singleFile(let fileExtension):
            guard Self.isValidFileExtension(fileExtension) else {
                throw RecordingOutputRequestError.invalidFileExtension
            }
            self.shape = .singleFile(fileExtension: fileExtension.lowercased())
        case .directory:
            self.shape = .directory
        }

        self.destinationDirectory = destinationDirectory
        self.stem = stem
        self.segmentIndex = segmentIndex
    }

    private static func isValidFileExtension(_ fileExtension: String) -> Bool {
        guard !fileExtension.isEmpty else { return false }
        return fileExtension.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }
}

/// Validation failures raised while creating a `RecordingOutputRequest`.
public enum RecordingOutputRequestError: Error, Equatable, Sendable {
    /// The stem was empty.
    case emptyStem
    /// The stem would escape or hide the destination path.
    case invalidStem
    /// The segment index was negative.
    case negativeSegmentIndex
    /// The file extension was empty or contained characters outside `[A-Za-z0-9]`.
    case invalidFileExtension
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

    static func supportsExclusiveRename(_ directoryURL: URL) -> Bool {
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

    static func renameExclusively(from sourceURL: URL, to destinationURL: URL) -> AtomicFileOperationResult {
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

/// Publishes a staged directory only through a same-volume exclusive rename.
///
/// A directory can never be published by a hard link, so this publisher has no
/// hard-link operation. Failures leave the staging directory in place.
struct AtomicDirectoryOutputPublisher {
    private let exclusiveRenameSupported: (URL) -> Bool
    private let exclusiveRenameOperation: (URL, URL) -> AtomicFileOperationResult

    init(
        exclusiveRenameSupported: @escaping (URL) -> Bool =
            AtomicRecordingOutputPublisher.supportsExclusiveRename,
        exclusiveRenameOperation: @escaping (URL, URL) -> AtomicFileOperationResult =
            AtomicRecordingOutputPublisher.renameExclusively
    ) {
        self.exclusiveRenameSupported = exclusiveRenameSupported
        self.exclusiveRenameOperation = exclusiveRenameOperation
    }

    func publish(stagingURL: URL, finalURL: URL) throws {
        let destinationDirectory = finalURL.deletingLastPathComponent()
        guard exclusiveRenameSupported(destinationDirectory) else {
            throw RecordingOutputTransactionError.unsupportedDestination
        }

        switch exclusiveRenameOperation(stagingURL, finalURL) {
        case .succeeded:
            return
        case .destinationExists:
            throw RecordingOutputTransactionError.destinationAlreadyExists
        case .unsupported:
            throw RecordingOutputTransactionError.unsupportedDestination
        case .failed:
            throw RecordingOutputTransactionError.publicationFailed
        }
    }
}

/// Reserves a hidden partial output and publishes it without overwriting an existing destination.
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
    /// Unique user-visible destination: a file, or a directory for directory output.
    public let finalURL: URL

    private let fileManager: FileManager
    private let filePublisher: AtomicRecordingOutputPublisher
    private let directoryPublisher: AtomicDirectoryOutputPublisher
    private let directoryOutput: Bool
    private var state = State.reserved

    /// Whether this transaction publishes a directory instead of a single file.
    public var isDirectoryOutput: Bool {
        directoryOutput
    }

    /// Whether the writer finished and the partial output is still on disk, so publication can be retried.
    public var isPublishable: Bool {
        guard state == .finished else { return false }
        if directoryOutput {
            return Self.isDirectory(partialURL)
        }
        return fileManager.fileExists(atPath: partialURL.path)
    }

    /// Reserves a hidden partial file and a unique final MP4 filename.
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

    /// Reserves a hidden partial file or staging directory for a validated request.
    ///
    /// Single-file requests keep the existing file publication behavior. Directory
    /// requests reserve a hidden same-parent staging directory and publish only by
    /// an exclusive rename of that directory.
    ///
    /// - Parameters:
    ///   - request: Validated naming request for this segment.
    ///   - now: Accepted for call-site symmetry with the legacy initializer; request names do not use it.
    ///   - timeZone: Accepted for call-site symmetry with the legacy initializer; request names do not use it.
    ///   - fileManager: File manager used for filesystem operations.
    /// - Throws: `RecordingOutputTransactionError` if the destination is missing or a partial cannot be reserved.
    public convenience init(
        request: RecordingOutputRequest,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            request: request,
            fileManager: fileManager,
            identifierProvider: UUID.init,
            filePublisher: AtomicRecordingOutputPublisher(),
            directoryPublisher: AtomicDirectoryOutputPublisher()
        )
    }

    convenience init(
        destinationDirectory: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default,
        identifierProvider: @escaping () -> UUID,
        publisher: AtomicRecordingOutputPublisher
    ) throws {
        let urls = try Self.reserveLegacyURLs(
            in: destinationDirectory,
            now: now,
            timeZone: timeZone,
            fileManager: fileManager,
            identifierProvider: identifierProvider
        )
        self.init(
            partialURL: urls.partial,
            finalURL: urls.final,
            isDirectoryOutput: false,
            fileManager: fileManager,
            filePublisher: publisher,
            directoryPublisher: AtomicDirectoryOutputPublisher()
        )
    }

    convenience init(
        request: RecordingOutputRequest,
        fileManager: FileManager = .default,
        identifierProvider: @escaping () -> UUID,
        filePublisher: AtomicRecordingOutputPublisher,
        directoryPublisher: AtomicDirectoryOutputPublisher
    ) throws {
        let urls = try Self.reserveURLs(
            for: request,
            fileManager: fileManager,
            identifierProvider: identifierProvider
        )
        self.init(
            partialURL: urls.partial,
            finalURL: urls.final,
            isDirectoryOutput: request.isDirectoryOutput,
            fileManager: fileManager,
            filePublisher: filePublisher,
            directoryPublisher: directoryPublisher
        )
    }

    private init(
        partialURL: URL,
        finalURL: URL,
        isDirectoryOutput: Bool,
        fileManager: FileManager,
        filePublisher: AtomicRecordingOutputPublisher,
        directoryPublisher: AtomicDirectoryOutputPublisher
    ) {
        self.partialURL = partialURL
        self.finalURL = finalURL
        self.directoryOutput = isDirectoryOutput
        self.fileManager = fileManager
        self.filePublisher = filePublisher
        self.directoryPublisher = directoryPublisher
    }

    /// Prepares the reserved output for the writer.
    ///
    /// Single-file outputs remove the zero-byte reservation immediately before
    /// creating the writer. Directory outputs keep their staging directory and
    /// require it to still be a real directory; a symlink replacement is rejected.
    ///
    /// - Throws: `RecordingOutputTransactionError` when the transaction is not
    ///   reserved or the partial output is missing.
    public func prepareForWriting() throws {
        guard state == .reserved else { throw RecordingOutputTransactionError.invalidState }
        if directoryOutput {
            guard Self.isDirectory(partialURL) else {
                throw RecordingOutputTransactionError.partialFileMissing
            }
        } else {
            guard fileManager.fileExists(atPath: partialURL.path) else {
                throw RecordingOutputTransactionError.partialFileMissing
            }
            try fileManager.removeItem(at: partialURL)
        }
        state = .writing
    }

    /// Records successful writer finalization before the output can be published.
    ///
    /// Both shapes require the partial file or staging directory to exist.
    /// Directory staging must still be a real directory; a symlink replacement
    /// is rejected. Directory content completeness is validated by the sealing layer.
    ///
    /// - Throws: `RecordingOutputTransactionError` when the transaction is not
    ///   writing or the partial output is missing.
    public func markWriterFinished() throws {
        guard state == .writing else { throw RecordingOutputTransactionError.invalidState }
        if directoryOutput {
            guard Self.isDirectory(partialURL) else {
                throw RecordingOutputTransactionError.partialFileMissing
            }
        } else {
            guard fileManager.fileExists(atPath: partialURL.path) else {
                throw RecordingOutputTransactionError.partialFileMissing
            }
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

        if Self.lstatStatus(at: partialURL) != nil {
            try fileManager.removeItem(at: partialURL)
        }
        state = .discarded
    }

    /// Publishes the finished output without overwriting an existing destination.
    ///
    /// Single-file outputs use the existing hard-link or exclusive-rename
    /// publisher. Directory outputs only use an exclusive rename of the owned
    /// staging directory and never create hard links. If publication fails,
    /// the partial or staging output remains available for recovery.
    ///
    /// - Returns: The final output URL.
    /// - Throws: `RecordingOutputTransactionError` if the writer is unfinished,
    ///   the partial is missing, or the destination cannot be published atomically
    ///   without replacement.
    public func publish() throws -> URL {
        guard state == .finished else { throw RecordingOutputTransactionError.writerNotFinished }
        guard fileManager.fileExists(atPath: partialURL.path) else {
            throw RecordingOutputTransactionError.partialFileMissing
        }

        if directoryOutput {
            guard Self.isDirectory(partialURL) else {
                throw RecordingOutputTransactionError.partialFileMissing
            }
            try directoryPublisher.publish(stagingURL: partialURL, finalURL: finalURL)
            state = .published
            return finalURL
        }

        let method = try filePublisher.publish(partialURL: partialURL, finalURL: finalURL)

        state = .published
        if method == .hardLink {
            try? fileManager.removeItem(at: partialURL)
        }
        return finalURL
    }

    private static func reserveLegacyURLs(
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

    private static func reserveURLs(
        for request: RecordingOutputRequest,
        fileManager: FileManager,
        identifierProvider: () -> UUID
    ) throws -> (partial: URL, final: URL) {
        var destinationIsDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: request.destinationDirectory.path,
                isDirectory: &destinationIsDirectory
            ), destinationIsDirectory.boolValue
        else {
            throw RecordingOutputTransactionError.invalidDestinationDirectory
        }

        let baseName = "\(request.stem)-\(segmentText(for: request.segmentIndex))"
        let fileExtension: String?
        if case .singleFile(let normalizedExtension) = request.shape {
            fileExtension = normalizedExtension
        } else {
            fileExtension = nil
        }

        var suffix: Int?
        while true {
            let suffixText = suffix.map { "_\($0)" } ?? ""
            let name = "\(baseName)\(suffixText)"
            let final: URL
            if let fileExtension {
                final = request.destinationDirectory
                    .appendingPathComponent("\(name).\(fileExtension)")
            } else {
                final = request.destinationDirectory
                    .appendingPathComponent(name, isDirectory: true)
            }
            guard !fileManager.fileExists(atPath: final.path) else {
                suffix = (suffix ?? 1) + 1
                continue
            }

            let partial: URL
            let creationResult: ExclusivePartialCreationResult
            if let fileExtension {
                partial = request.destinationDirectory.appendingPathComponent(
                    ".SnapGlass-\(identifierProvider().uuidString).\(fileExtension).partial"
                )
                creationResult = createExclusivePartial(at: partial)
            } else {
                partial = request.destinationDirectory.appendingPathComponent(
                    ".SnapGlass-\(identifierProvider().uuidString).staging",
                    isDirectory: true
                )
                creationResult = createExclusiveDirectory(at: partial)
            }

            switch creationResult {
            case .created:
                return (partial, final)
            case .alreadyExists:
                continue
            case .failed:
                throw RecordingOutputTransactionError.unableToReservePartialFile
            }
        }
    }

    private static func segmentText(for index: Int) -> String {
        let digits = String(index)
        return String(repeating: "0", count: max(0, 2 - digits.count)) + digits
    }

    private static func createExclusiveDirectory(at url: URL) -> ExclusivePartialCreationResult {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .failed }
            guard Darwin.mkdir(path, mode_t(0o700)) == 0 else {
                return errno == EEXIST ? .alreadyExists : .failed
            }
            return .created
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let status = lstatStatus(at: url) else { return false }
        return status.st_mode & S_IFMT == S_IFDIR
    }

    private static func lstatStatus(at url: URL) -> stat? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        return result == 0 ? status : nil
    }
}

private extension RecordingOutputRequest {
    var isDirectoryOutput: Bool {
        if case .directory = shape {
            return true
        }
        return false
    }
}

private enum ExclusivePartialCreationResult {
    case created
    case alreadyExists
    case failed
}
