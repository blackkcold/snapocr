import CryptoKit
import Darwin
import Foundation

/// Foundation's thread-safe file manager is wrapped for transfer across actors.
struct RecordingSendableFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) { self.value = value }
}

/// The rebuildable session index. The per-session journal remains authoritative.
public struct RecordingIndexRecord: Codable, Sendable, Hashable {
    /// Current on-disk cache schema.
    public static let currentSchemaVersion = 2

    /// One session entry whose root is relative to the supplied recording root.
    public struct Entry: Codable, Sendable, Hashable {
        /// Identity of the indexed session.
        public let sessionID: UUID
        /// Session root relative to the recording root, so the entry survives a root move.
        public let sessionRootRelativePath: String
        /// Cached session record; the session journal remains authoritative.
        public let record: RecordingSessionRecord

        /// Creates an index entry.
        public init(
            sessionID: UUID,
            sessionRootRelativePath: String,
            record: RecordingSessionRecord
        ) {
            self.sessionID = sessionID
            self.sessionRootRelativePath = sessionRootRelativePath
            self.record = record
        }
    }

    /// Schema version this cache was written with; a mismatched cache is rebuilt.
    public let schemaVersion: Int
    /// One entry per discovered session.
    public let entries: [Entry]
    /// Wall-clock time at which the cache was last written.
    public let updatedAt: Date

    /// Creates an index record.
    ///
    /// - Parameters:
    ///   - schemaVersion: Cache schema to write.
    ///   - entries: Session entries to store.
    ///   - updatedAt: Wall-clock write time.
    public init(
        schemaVersion: Int = RecordingIndexRecord.currentSchemaVersion,
        entries: [Entry],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.updatedAt = updatedAt
    }
}

enum RecordingLedgerFileError: Error, Equatable {
    case invalidPath
    case pathEscapesRoot
    case symbolicLink
    case unexpectedFileType
    case ioFailure
    case hashMismatch
}

/// Shared path and durability helpers for T9's journal, cache, preview and GC.
enum RecordingLedgerFileSystem {
    static func canonicalDirectory(_ url: URL, create: Bool) throws -> URL {
        guard url.isFileURL, !url.path.isEmpty, !url.path.contains("\0"),
            url.standardizedFileURL.path == url.path
        else { throw RecordingLedgerFileError.invalidPath }
        if create, !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
                )
            } catch { throw RecordingLedgerFileError.ioFailure }
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.isFileURL, isDirectory(resolved) else {
            throw RecordingLedgerFileError.unexpectedFileType
        }
        return resolved
    }

    static func canonicalFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.isEmpty, !url.path.contains("\0"),
            url.standardizedFileURL.path == url.path,
            !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".."
        else { throw RecordingLedgerFileError.invalidPath }
        return url.standardizedFileURL
    }

    static func validateNoSymlink(_ url: URL, allowingMissing: Bool = false) throws {
        let path = try canonicalFileURL(url).path
        var missing = false
        var candidate = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: path).pathComponents where component != "/" {
            candidate.appendPathComponent(component)
            if missing { continue }
            guard let mode = mode(at: candidate) else {
                if allowingMissing {
                    missing = true
                    continue
                }
                throw RecordingLedgerFileError.ioFailure
            }
            if mode & S_IFMT == S_IFLNK { throw RecordingLedgerFileError.symbolicLink }
        }
    }

    static func validateChild(_ url: URL, under root: URL, allowingMissing: Bool = false) throws -> String {
        let safeRoot = root.standardizedFileURL.path
        let safeURL = try canonicalFileURL(url)
        let prefix = safeRoot.hasSuffix("/") ? safeRoot : safeRoot + "/"
        guard safeURL.path.hasPrefix(prefix) else { throw RecordingLedgerFileError.pathEscapesRoot }
        let relative = String(safeURL.path.dropFirst(prefix.count))
        try validateRelativePath(relative)
        try validateNoSymlink(safeURL, allowingMissing: allowingMissing)
        return relative
    }

    static func resolve(_ relativePath: String, under root: URL, allowingMissing: Bool = false) throws -> URL {
        try validateRelativePath(relativePath)
        let result = root.appendingPathComponent(relativePath).standardizedFileURL
        _ = try validateChild(result, under: root, allowingMissing: allowingMissing)
        return result
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
            !path.contains("\\")
        else { throw RecordingLedgerFileError.invalidPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RecordingLedgerFileError.pathEscapesRoot
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        mode(at: url).map { $0 & S_IFMT == S_IFREG } ?? false
    }

    static func isDirectory(_ url: URL) -> Bool {
        mode(at: url).map { $0 & S_IFMT == S_IFDIR } ?? false
    }

    static func mode(at url: URL) -> mode_t? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        return result == 0 ? info.st_mode : nil
    }

    static func sha256(of url: URL) throws -> String {
        guard isRegularFile(url) else { throw RecordingLedgerFileError.unexpectedFileType }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw RecordingLedgerFileError.ioFailure }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        } catch { throw RecordingLedgerFileError.ioFailure }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func syncFile(_ url: URL) throws {
        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else { throw RecordingLedgerFileError.ioFailure }
        defer { _ = Darwin.close(fileDescriptor) }
        if Darwin.fcntl(fileDescriptor, F_FULLFSYNC) == -1, Darwin.fsync(fileDescriptor) != 0 {
            throw RecordingLedgerFileError.ioFailure
        }
    }

    static func syncDirectory(_ url: URL) throws {
        let fileDescriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else { throw RecordingLedgerFileError.ioFailure }
        defer { _ = Darwin.close(fileDescriptor) }
        guard Darwin.fsync(fileDescriptor) == 0 else { throw RecordingLedgerFileError.ioFailure }
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let destination = try canonicalFileURL(url)
        let parent = destination.deletingLastPathComponent()
        try validateNoSymlink(parent)
        try validateNoSymlink(destination, allowingMissing: true)
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try syncFile(temporary)
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    guard let source, let target else { return Int32(-1) }
                    return Darwin.rename(source, target)
                }
            }
            guard result == 0 else { throw RecordingLedgerFileError.ioFailure }
            try syncDirectory(parent)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? RecordingLedgerFileError { throw error }
            throw RecordingLedgerFileError.ioFailure
        }
    }
}
