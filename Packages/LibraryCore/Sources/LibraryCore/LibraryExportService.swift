import CaptureCore
import CoreGraphics
import Foundation
import HistoryCore
import ImageIO
import LibraryCore
import OSLog
import UniformTypeIdentifiers

/// Directory layout used when exporting library items.
public enum LibraryExportLayout: String, CaseIterable, Sendable {
    /// Write every file directly into the destination folder.
    case flat
    /// Group files into `Screenshots`, `Audio` and `Video` subfolders.
    case byType
    /// Group files into `yyyy-MM-dd` subfolders by item date.
    case byDate
}

/// Options for a library export.
public struct LibraryExportOptions: Sendable {
    /// Folder that receives the exported files. It must already exist.
    public var destination: URL
    /// Subfolder layout below `destination`.
    public var layout: LibraryExportLayout
    /// Whether to write a `manifest.csv` next to the exported files.
    public var includeManifest: Bool

    /// Creates export options with the given values.
    ///
    /// - Parameters:
    ///   - destination: Folder that receives the exported files; defaults to
    ///     `LibraryPaths.defaultExportDirectory`.
    ///   - layout: Subfolder layout; defaults to `.byType`.
    ///   - includeManifest: Whether to write a `manifest.csv`; defaults to `true`.
    public init(
        destination: URL = LibraryPaths.defaultExportDirectory,
        layout: LibraryExportLayout = .byType,
        includeManifest: Bool = true
    ) {
        self.destination = destination
        self.layout = layout
        self.includeManifest = includeManifest
    }
}

/// Progress update emitted once per exported item.
public struct LibraryExportProgress: Sendable {
    /// Completed fraction of the export, in the range `0...1`.
    public let fraction: Double
    /// Localized status message suitable for display.
    public let message: String
}

/// Outcome of a library export.
public struct LibraryExportResult: Sendable {
    /// Files written during the export, in export order.
    public let outputURLs: [URL]
    /// Localized messages for items that could not be exported. Other items are
    /// still exported.
    public let failures: [String]
    /// Localized non-fatal warnings, such as a legacy media lookup.
    public let warnings: [String]
    /// Location of the written manifest, or `nil` when no manifest was requested
    /// or there was nothing to list.
    public let manifestURL: URL?
}

/// Errors reported by a library export.
public enum LibraryExportError: Error, LocalizedError {
    /// No items were selected for export.
    case noItems
    /// Screenshot export was requested but history storage is unavailable.
    case historyUnavailable
    /// The destination folder does not exist.
    case destinationUnavailable

    /// Localized description of the failure.
    public var errorDescription: String? {
        switch self {
        case .noItems:
            return LibraryLocalization.string("Choose at least one item to export.")
        case .historyUnavailable:
            return LibraryLocalization.string("History storage is unavailable.")
        case .destinationUnavailable:
            return LibraryLocalization.string("Choose an existing writable destination folder.")
        }
    }
}

/// Exports screenshots and recordings as ordinary files. Merging is a separate
/// action; this service never silently joins segments and never deletes media.
public actor LibraryExportService {
    private struct ManifestRow {
        let kind: String
        let title: String
        let date: Date
        let duration: TimeInterval
        let byteSize: Int64
        let segments: Int
        let source: String
        let output: String
        let favourite: Bool
    }

    private let fileManager: FileManager
    private let mediaResolver: RecordingMediaResolver
    private let logger = Logger(subsystem: "com.snapglass.app", category: "LibraryExport")

    /// Creates an export service.
    ///
    /// - Parameter fileManager: File manager used to create folders, copy media
    ///   and write the manifest.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.mediaResolver = RecordingMediaResolver()
    }

    // The per-item switch writes screenshots and recordings into one manifest;
    // splitting it would duplicate the failure and manifest bookkeeping.
    /// Exports library items as ordinary files.
    ///
    /// Each screenshot is written from history storage; each recording is copied
    /// through `RecordingPreviewService` leases so the journal stays the only
    /// source of truth. A failure for one item is reported in
    /// `LibraryExportResult.failures` and does not stop the remaining items.
    /// Nothing is deleted or merged.
    ///
    /// - Parameters:
    ///   - items: Screenshots and recordings to export.
    ///   - options: Destination folder, layout and manifest choice.
    ///   - progress: Called after each item with the completed fraction and a
    ///     localized message.
    /// - Returns: The files written, per-item failures, warnings and the manifest
    ///   location.
    /// - Throws: `LibraryExportError.noItems` when `items` is empty,
    ///   `.destinationUnavailable` when the destination folder does not exist,
    ///   `.historyUnavailable` when a screenshot is selected and history storage
    ///   is unavailable, or `CancellationError` when the task is cancelled. A
    ///   file-system error while creating a destination folder or writing the
    ///   manifest is also thrown.
    public func export(  // swiftlint:disable:this function_body_length
        items: [LibraryItem],
        options: LibraryExportOptions,
        progress: @escaping @Sendable (LibraryExportProgress) -> Void
    ) async throws -> LibraryExportResult {
        guard !items.isEmpty else { throw LibraryExportError.noItems }
        guard fileManager.fileExists(atPath: options.destination.path) else {
            throw LibraryExportError.destinationUnavailable
        }

        let history = HistoryActor.shared
        if items.contains(where: { $0.screenshot != nil }), history == nil {
            throw LibraryExportError.historyUnavailable
        }

        var outputURLs: [URL] = []
        var failures: [String] = []
        var warnings: [String] = []
        var manifest: [ManifestRow] = []

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let folder = try folder(for: item, options: options)
            do {
                switch item {
                case .screenshot(let entry):
                    guard let history else { throw LibraryExportError.historyUnavailable }
                    let url = try await exportScreenshot(entry, history: history, to: folder)
                    outputURLs.append(url)
                    manifest.append(
                        ManifestRow(
                            kind: "screenshot",
                            title: screenshotTitle(entry),
                            date: entry.timestamp,
                            duration: 0,
                            byteSize: fileSize(of: url),
                            segments: 1,
                            source: "history",
                            output: url.path,
                            favourite: entry.isFavourite
                        )
                    )
                case .recording(let group):
                    let recordingResult = try await exportRecording(group, to: folder)
                    outputURLs.append(contentsOf: recordingResult.urls)
                    warnings.append(contentsOf: recordingResult.warnings)
                    let urls = recordingResult.urls
                    for url in urls {
                        manifest.append(
                            ManifestRow(
                                kind: group.kind == .audio ? "audio" : "video",
                                title: displayTitle(for: group),
                                date: group.startedAt,
                                duration: group.duration,
                                byteSize: group.byteSize,
                                segments: group.segmentCount,
                                source: group.roots.first?.path ?? "",
                                output: url.path,
                                favourite: group.isFavourite
                            )
                        )
                    }
                    if urls.isEmpty {
                        failures.append(
                            LibraryLocalization.string(
                                "No media was found for %@.",
                                displayTitle(for: group)
                            )
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(
                    LibraryLocalization.string(
                        "Could not export %@: %@",
                        displayTitle(for: item),
                        error.localizedDescription
                    )
                )
                logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            }
            progress(
                LibraryExportProgress(
                    fraction: Double(index + 1) / Double(items.count),
                    message: LibraryLocalization.string("Exporting %@ of %@…", String(index + 1), String(items.count))
                )
            )
        }

        var manifestURL: URL?
        if options.includeManifest, !manifest.isEmpty {
            manifestURL = try writeManifest(
                manifest,
                to: options.destination.appendingPathComponent("manifest.csv")
            )
        }

        return LibraryExportResult(
            outputURLs: outputURLs,
            failures: failures,
            warnings: warnings,
            manifestURL: manifestURL
        )
    }

    // MARK: - Destinations

    private func folder(for item: LibraryItem, options: LibraryExportOptions) throws -> URL {
        let folder: URL
        switch options.layout {
        case .flat:
            folder = options.destination
        case .byType:
            let name: String
            switch item.mediaKind {
            case .screenshot: name = "Screenshots"
            case .audio: name = "Audio"
            case .video: name = "Video"
            }
            folder = options.destination.appendingPathComponent(name, isDirectory: true)
        case .byDate:
            folder = options.destination.appendingPathComponent(
                dayString(item.date),
                isDirectory: true
            )
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Screenshots

    private func exportScreenshot(
        _ entry: HistoryEntry,
        history: HistoryActor,
        to folder: URL
    ) async throws -> URL {
        guard let data = try await history.imageData(for: entry.id) else {
            throw LibraryExportError.historyUnavailable
        }
        let ext = imageExtension(for: data)
        let base = sanitized(
            "\(screenshotTitle(entry))-\(timestamp(entry.timestamp))"
        )
        let destination = uniqueURL(
            folder.appendingPathComponent("\(base).\(ext)")
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func screenshotTitle(_ entry: HistoryEntry) -> String {
        let raw =
            entry.sourceWindowTitle
            ?? entry.sourceAppName
            ?? LibraryLocalization.string("Screenshot")
        return sanitized(raw)
    }

    private func imageExtension(for data: Data) -> String {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?,
            let utType = UTType(type),
            let preferred = utType.preferredFilenameExtension
        else { return "png" }
        return preferred.lowercased() == "jpeg" ? "jpg" : preferred.lowercased()
    }

    // MARK: - Recordings

    private func exportRecording(
        _ group: LibraryRecordingGroup,
        to folder: URL
    ) async throws -> (urls: [URL], warnings: [String]) {
        var written: [URL] = []
        let publishedSegments = group.segments
            .filter { $0.state == .published }
            .sorted { $0.index < $1.index }

        guard !publishedSegments.isEmpty else { return ([], []) }

        var resolved: [UUID: [URL]] = [:]
        var leaseService: RecordingPreviewService?
        var leases: [RecordingMediaLease] = []

        for root in group.roots {
            let indexURL =
                root
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent("recording-index.json")
            do {
                let result = try await mediaResolver.lease(
                    sessionID: group.sessionID,
                    root: root,
                    indexURL: indexURL,
                    segmentIDs: publishedSegments.map(\.id),
                    duration: 3_600
                )
                leaseService = result.service
                leases = result.leases
                for lease in result.leases {
                    resolved[lease.segmentID] = lease.urls
                }
                break
            } catch {
                continue
            }
        }

        do {
            for segment in publishedSegments {
                try Task.checkCancellation()
                let segmentURLs = resolved[segment.id] ?? segment.mediaURLs
                let topLevel = topLevelURLs(segmentURLs)
                for source in topLevel {
                    let ext = source.pathExtension
                    let suffix = publishedSegments.count > 1 ? "-\(segment.displayIndex)" : ""
                    let proposedName = "\(displayTitle(for: group))\(suffix)\(ext.isEmpty ? "" : ".\(ext)")"
                    let destination = uniqueURL(
                        folder.appendingPathComponent(sanitized(proposedName))
                    )
                    do {
                        try fileManager.copyItem(at: source, to: destination)
                        written.append(destination)
                    } catch {
                        logger.error(
                            // swiftlint:disable:next line_length
                            "Copy failed \(source.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        } catch {
            if let leaseService {
                await mediaResolver.release(leases, using: leaseService)
            }
            throw error
        }

        if let leaseService {
            await mediaResolver.release(leases, using: leaseService)
        }

        var warnings: [String] = []
        if leaseService == nil, !publishedSegments.isEmpty {
            warnings.append(
                LibraryLocalization.string(
                    "Used the legacy file lookup for %@; verify the exported files.",
                    displayTitle(for: group)
                )
            )
        }
        return (written, warnings)
    }

    private func topLevelURLs(_ urls: [URL]) -> [URL] {
        urls
            .map(\.standardizedFileURL)
            .sorted { $0.path.count < $1.path.count }
            .reduce(into: [URL]()) { result, url in
                if result.contains(where: { isContained(url, in: $0) }) { return }
                result.append(url)
            }
    }

    private func isContained(_ url: URL, in directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = directory.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    // MARK: - Manifest

    private func writeManifest(_ rows: [ManifestRow], to proposedURL: URL) throws -> URL {
        let url = uniqueURL(proposedURL)
        let header = "type,title,date,duration,size,segments,source,output,favourite\n"
        var csv = header
        for row in rows {
            let fields = [
                row.kind,
                row.title,
                timestamp(row.date),
                String(format: "%.1f", row.duration),
                String(row.byteSize),
                String(row.segments),
                row.source,
                row.output,
                row.favourite ? "true" : "false",
            ]
            csv += fields.map(csvField).joined(separator: ",") + "\n"
        }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(csv.data(using: .utf8) ?? Data())
        try data.write(to: url, options: .atomic)
        return url
    }

    private func csvField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    // MARK: - Helpers

    private func displayTitle(for group: LibraryRecordingGroup) -> String {
        if !group.title.isEmpty { return sanitized(group.title) }
        let kind =
            group.kind == .audio
            ? LibraryLocalization.string("Audio Recording")
            : LibraryLocalization.string("Screen Recording")
        return sanitized("\(kind)-\(timestamp(group.startedAt))")
    }

    private func displayTitle(for item: LibraryItem) -> String {
        switch item {
        case .screenshot(let entry): return screenshotTitle(entry)
        case .recording(let group): return displayTitle(for: group)
        }
    }

    private func sanitized(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var value =
            raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = LibraryLocalization.string("Untitled") }
        return String(value.prefix(80))
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func uniqueURL(_ proposed: URL) -> URL {
        var candidate = proposed
        var suffix = 2
        let ext = proposed.pathExtension
        let base = proposed.deletingPathExtension().lastPathComponent
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            candidate = proposed.deletingLastPathComponent().appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    private func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0
    }
}
