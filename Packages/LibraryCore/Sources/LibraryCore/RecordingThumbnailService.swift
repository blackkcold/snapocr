import AVFoundation
import CaptureCore
import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Generates and caches poster frames for screen recordings.
///
/// Audio cards use a lightweight SwiftUI waveform illustration; video cards
/// need a real frame so the library is visually scannable. Generation is
/// lazy, off the main actor, and failures degrade to a placeholder rather than
/// blocking the list.
public actor RecordingThumbnailService {
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.snapglass.app", category: "LibraryThumbnail")
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(
        cacheDirectory: URL = LibraryPaths.thumbnailDirectory,
        fileManager: FileManager = .default
    ) {
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Removes stale poster frames and enforces a disk budget.
    ///
    /// Old files are removed first, then the oldest remaining files until the
    /// total size fits. This is intentionally best-effort: a failed unlink must
    /// never block opening the library.
    public func pruneCache(
        olderThan age: TimeInterval = 30 * 24 * 60 * 60,
        maxBytes: Int64 = 500 * 1024 * 1024
    ) {
        let fileManager = self.fileManager
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        var entries: [(url: URL, date: Date, size: Int64)] = []
        for url in urls {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            entries.append(
                (
                    url,
                    values.contentModificationDate ?? .distantPast,
                    Int64(values.fileSize ?? 0)
                )
            )
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard entry.date < cutoff || total > maxBytes else { continue }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    public func thumbnailData(for group: LibraryRecordingGroup) async -> Data? {        guard group.kind == .screen, let url = group.coverURL else { return nil }
        let key = cacheKey(for: group, url: url)
        let cacheURL = cacheDirectory.appendingPathComponent("\(key).png")
        if let data = try? Data(contentsOf: cacheURL) {
            return data
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<Data?, Never> {
            await Self.generatePosterData(
                url: url,
                cacheURL: cacheURL,
                cacheDirectory: cacheDirectory
            )
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if data == nil {
            logger.debug("No poster frame for \(url.lastPathComponent, privacy: .public)")
        }
        return data
    }

    private func cacheKey(for group: LibraryRecordingGroup, url: URL) -> String {
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let size = values?.fileSize ?? 0
        return "\(group.sessionID.uuidString)-\(modified)-\(size)"
    }

    private nonisolated static func generatePosterData(
        url: URL,
        cacheURL: URL,
        cacheDirectory: URL
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            let time = CMTime(seconds: 1, preferredTimescale: 600)
            do {
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                guard let data = pngData(from: image) else { return nil }
                try? FileManager.default.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
                try? data.write(to: cacheURL, options: .atomic)
                return data
            } catch {
                return nil
            }
        }.value
    }

    private nonisolated static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
