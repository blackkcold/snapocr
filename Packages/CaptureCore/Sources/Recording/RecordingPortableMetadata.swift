import Darwin
import Foundation

/// Task 9 facade over Task 8's asynchronous portable-metadata carrier.
public enum RecordingPortableMetadata {
    /// Embeds the record by remuxing to a sibling file and atomically replacing `url`.
    public static func embed(into url: URL, record: SegmentPortableRecord) async throws {
        guard url.pathExtension.lowercased() == "m4a",
              RecordingLedgerFileSystem.isRegularFile(url)
        else { throw RecordingSealError.metadataInvalid }
        do { try RecordingLedgerFileSystem.validateNoSymlink(url) } catch { throw RecordingSealError.metadataInvalid }

        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".SnapGlass-\(UUID().uuidString)-portable.m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        // T8 owns the native passthrough remux and remains fully asynchronous here.
        try await SegmentPortableMetadata.embed(record, from: url, to: temporary)
        guard try await SegmentPortableMetadata.read(from: temporary) == record else {
            throw RecordingSealError.metadataInvalid
        }
        do {
            try RecordingLedgerFileSystem.validateNoSymlink(url)
            try RecordingLedgerFileSystem.validateNoSymlink(temporary)
            let result = temporary.withUnsafeFileSystemRepresentation { source in
                url.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination else { return Int32(-1) }
                    return Darwin.rename(source, destination)
                }
            }
            guard result == 0 else { throw RecordingSealError.metadataExportFailed }
            try RecordingLedgerFileSystem.syncFile(url)
            try RecordingLedgerFileSystem.syncDirectory(directory)
        } catch let error as RecordingSealError {
            throw error
        } catch {
            throw RecordingSealError.metadataExportFailed
        }
    }

    /// Reads the portable record using Task 8's asynchronous AVFoundation helper.
    public static func read(from url: URL) async throws -> SegmentPortableRecord {
        try await SegmentPortableMetadata.read(from: url)
    }
}
