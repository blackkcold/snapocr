import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension HistoryActor {
    public static let imagesDidChange = Notification.Name("SnapGlass.historyImagesDidChange")

    /// Write new immutable media first, then atomically switch the encrypted
    /// metadata reference. Any failure leaves the old image and original intact.
    public func replaceImage(id: UUID, image: CGImage) throws {
        guard var entry = entries[id] ?? diskCache[id] ?? loadEntryFromDiskSync(id: id),
              entry.imagePath != nil else { throw HistoryError.entryNotFound(id: id) }
        let originalURL = mediaURL(for: id, revision: nil, thumbnail: false)
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw HistoryError.fileIOError(path: originalURL.path)
        }
        // Verify the recovery copy before offering a reversible replacement.
        _ = try cryptoService.decrypt(Data(contentsOf: originalURL))
        let revision = UUID()
        let imageURL = mediaURL(for: id, revision: revision, thumbnail: false)
        let thumbURL = mediaURL(for: id, revision: revision, thumbnail: true)
        do {
            let data = try Self.pngData(image)
            try cryptoService.encrypt(data).write(to: imageURL, options: .atomic)
            let thumb = try Self.thumbnail(from: data)
            try thumb.write(to: thumbURL, options: .atomic)
            entry.imageRevision = revision
            entry.imagePath = imageURL
            entry.thumbnailPath = thumbURL
            entry.textContent = ""
            entry.ocrConfidence = 0
            try persistEntry(entry)
        } catch {
            for url in [imageURL, thumbURL] {
                do {
                    try removeIfExists(url)
                } catch {
                    logger.warning("Unable to remove uncommitted edit: \(url.lastPathComponent)")
                }
            }
            throw error
        }
        entries[id] = entry
        diskCache[id] = entry
        removeObsoleteEdits(for: entry)
        NotificationCenter.default.post(name: Self.imagesDidChange, object: nil)
    }

    public func restoreOriginal(id: UUID) throws {
        guard var entry = entries[id] ?? diskCache[id] ?? loadEntryFromDiskSync(id: id) else {
            throw HistoryError.entryNotFound(id: id)
        }
        guard entry.canRestoreOriginal else { return }
        let originalURL = mediaURL(for: id, revision: nil, thumbnail: false)
        let data = try cryptoService.decrypt(Data(contentsOf: originalURL))
        let thumbnailURL = mediaURL(for: id, revision: nil, thumbnail: true)
        try Self.thumbnail(from: data).write(to: thumbnailURL, options: .atomic)
        entry.imageRevision = nil
        entry.imagePath = originalURL
        entry.thumbnailPath = thumbnailURL
        entry.textContent = ""
        entry.ocrConfidence = 0
        try persistEntry(entry)
        entries[id] = entry
        diskCache[id] = entry
        removeObsoleteEdits(for: entry)
        NotificationCenter.default.post(name: Self.imagesDidChange, object: nil)
    }

    func mediaURL(for id: UUID, revision: UUID?, thumbnail: Bool) -> URL {
        let name = id.uuidString + (revision.map { "-\($0.uuidString)" } ?? "")
        return (thumbnail ? thumbsDir : imagesDir)
            .appendingPathComponent(name + (thumbnail ? ".png" : ".enc"))
    }

    func mediaFiles(for id: UUID, thumbnail: Bool? = nil) throws -> [URL] {
        let directories = thumbnail.map { [$0 ? thumbsDir : imagesDir] } ?? [imagesDir, thumbsDir]
        return try directories.flatMap { directory in
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { file in
                    let stem = file.deletingPathExtension().lastPathComponent
                    return stem == id.uuidString || (stem.hasPrefix(id.uuidString + "-")
                        && UUID(uuidString: String(stem.dropFirst(37))) != nil)
                }
        }
    }

    private func removeObsoleteEdits(for entry: HistoryEntry) {
        do {
            let keep = Set([
                mediaURL(for: entry.id, revision: nil, thumbnail: false),
                mediaURL(for: entry.id, revision: nil, thumbnail: true),
                imageFileURL(for: entry.id), thumbnailFileURL(for: entry.id),
            ].map { $0.standardizedFileURL.path })
            for file in try mediaFiles(for: entry.id) where !keep.contains(file.standardizedFileURL.path) {
                try removeIfExists(file)
            }
        } catch {
            logger.warning("Edit committed; obsolete media cleanup deferred for \(entry.id)")
        }
    }

    private static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw HistoryError.fileIOError(path: "PNG encoding")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HistoryError.fileIOError(path: "PNG encoding")
        }
        return data as Data
    }

    private static func thumbnail(from data: Data) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw HistoryError.fileIOError(path: "Thumbnail encoding") }
        return try pngData(image)
    }
}
