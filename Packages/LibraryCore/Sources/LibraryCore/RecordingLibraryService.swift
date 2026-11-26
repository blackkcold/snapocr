import CaptureCore
import Foundation
import LibraryCore
import OSLog

/// Read-only projection of the recording journals into the unified library.
///
/// Media URLs are resolved conservatively for display (poster frames, sizes).
/// Mutating operations (export, merge) still go through the official
/// `RecordingPreviewService` so the journal remains the only source of truth.
public actor RecordingLibraryService {
    private struct Candidate {
        var record: RecordingSessionRecord
        var roots: [URL]
    }

    private let roots: [LibraryRoot]
    private let metadataStore: RecordingLibraryStore
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.snapglass.app", category: "RecordingLibrary")

    /// Creates a library service.
    ///
    /// - Parameters:
    ///   - roots: Recording roots to scan, in priority order.
    ///   - metadataStore: Store that supplies titles, favourites, tags, notes and
    ///     manual groups.
    ///   - fileManager: File manager used for folder probes and size lookups.
    public init(
        roots: [LibraryRoot],
        metadataStore: RecordingLibraryStore,
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.metadataStore = metadataStore
        self.fileManager = fileManager
    }

    /// Rescans every root and projects its published sessions into a snapshot.
    ///
    /// A root whose folder no longer exists is listed in
    /// `RecordingLibrarySnapshot.offlineRoots` and skipped. A session found under
    /// several roots is reported once, with the record that has the most
    /// published segments and all of its roots. Titles, favourites, tags, notes
    /// and manual groups come from the metadata store; nothing is written back.
    /// Scan errors for a single root are logged and do not abort the scan.
    ///
    /// - Returns: The snapshot with session groups, projected manual groups
    ///   (newest first), offline roots, total byte size and the scan time.
    public func scan() async -> RecordingLibrarySnapshot {
        let metadata = await metadataStore.snapshot()
        var candidates: [UUID: Candidate] = [:]
        var offlineRoots: [String] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.root.path) else {
                offlineRoots.append(root.root.path)
                continue
            }
            do {
                let records = try await RecordingSessionLedger.publishedSessions(
                    in: root.root,
                    indexURL: root.indexURL
                )
                for record in records {
                    if var existing = candidates[record.id] {
                        if !existing.roots.contains(root.root) {
                            existing.roots.append(root.root)
                        }
                        if Self.prefer(record, over: existing.record) {
                            existing.record = record
                        }
                        candidates[record.id] = existing
                    } else {
                        candidates[record.id] = Candidate(record: record, roots: [root.root])
                    }
                }
            } catch {
                logger.error(
                    // swiftlint:disable:next line_length
                    "Failed to scan recording root \(root.root.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let sessionGroups = candidates.values
            .map { candidate in
                let entry = metadata.sessions[candidate.record.id.uuidString] ?? RecordingMetadataEntry()
                return makeGroup(record: candidate.record, roots: candidate.roots, entry: entry)
            }
            .sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.id < rhs.id
                }
                return lhs.startedAt > rhs.startedAt
            }

        let groups = LibraryManualGroupProjector.project(
            sessionGroups: sessionGroups,
            manualGroups: Array(metadata.groups.values)
        )
        .sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id < rhs.id
            }
            return lhs.startedAt > rhs.startedAt
        }

        let totalBytes = groups.reduce(Int64(0)) { $0 + $1.byteSize }
        return RecordingLibrarySnapshot(
            groups: groups,
            sessionGroups: sessionGroups,
            recoverable: [],
            offlineRoots: offlineRoots,
            totalBytes: totalBytes,
            scannedAt: Date()
        )
    }

    private static func prefer(
        _ lhs: RecordingSessionRecord,
        over rhs: RecordingSessionRecord
    ) -> Bool {
        let lhsPublished = lhs.segments.filter { $0.state == .published }.count
        let rhsPublished = rhs.segments.filter { $0.state == .published }.count
        if lhsPublished != rhsPublished { return lhsPublished > rhsPublished }
        if lhs.segments.count != rhs.segments.count { return lhs.segments.count > rhs.segments.count }
        return lhs.startedAt > rhs.startedAt
    }

    private func makeGroup(
        record: RecordingSessionRecord,
        roots: [URL],
        entry: RecordingMetadataEntry
    ) -> LibraryRecordingGroup {
        let segments = record.segments
            .sorted { lhs, rhs in
                if lhs.index == rhs.index { return lhs.startSample < rhs.startSample }
                return lhs.index < rhs.index
            }
            .map { makeSegment($0, sessionID: record.id, roots: roots) }

        let duration = segments.reduce(0.0) { $0 + $1.duration }
        let byteSize = segments.reduce(Int64(0)) { $0 + $1.byteSize }
        let missingCount = segments.filter { $0.state == .missing }.count
        let state: LibraryRecordingState =
            missingCount > 0
            ? .partial(missing: missingCount)
            : .complete

        let mediaURL =
            record.kind == .audio
            ? segments.compactMap(\.audioURL).first
            : segments.compactMap(\.videoURL).first
        let coverURL = mediaURL

        return LibraryRecordingGroup(
            sessionID: record.id,
            kind: record.kind,
            layout: record.layout,
            title: entry.displayName ?? "",
            startedAt: record.startedAt,
            duration: duration,
            byteSize: byteSize,
            segments: segments,
            state: state,
            isFavourite: entry.isFavourite,
            tags: entry.tags,
            note: entry.note,
            coverURL: coverURL,
            mediaURL: mediaURL,
            roots: roots
        )
    }

    private func makeSegment(
        _ segment: PublishedSegment,
        sessionID: UUID,
        roots: [URL]
    ) -> LibraryRecordingSegment {
        let urls = resolveURLs(for: segment, sessionID: sessionID, roots: roots)
        let byteSize = urls.reduce(Int64(0)) { $0 + fileSize(of: $1) }
        let videoURL = urls.first { $0.pathExtension.lowercased() == "mp4" }
        let audioURL = urls.first {
            ["m4a", "caf", "wav", "aiff", "aif"].contains($0.pathExtension.lowercased())
        }
        return LibraryRecordingSegment(
            id: segment.id,
            index: segment.index,
            duration: Double(max(0, segment.sampleCount)) / 48_000,
            byteSize: byteSize,
            state: segment.state,
            mediaURLs: urls,
            videoURL: videoURL,
            audioURL: audioURL,
            audioRoles: segment.files.keys.sorted(),
            missingRangeCount: segment.missingRanges.count,
            isAdopted: segment.materialURL != nil,
            sessionID: sessionID,
            root: roots.first
        )
    }

    private func resolveURLs(
        for segment: PublishedSegment,
        sessionID: UUID,
        roots: [URL]
    ) -> [URL] {
        var urls = Set<URL>()

        func add(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            urls.insert(standardized)
        }

        add(segment.videoURL)
        add(segment.materialURL)

        let sessionFolderName = sessionID.uuidString.lowercased()
        for root in roots {
            for relative in segment.files.values {
                add(root.appendingPathComponent(relative))
                add(
                    root
                        .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                        .appendingPathComponent(sessionFolderName, isDirectory: true)
                        .appendingPathComponent(relative)
                )
            }

            // Published filenames are derived from the session ID and segment
            // index. This is only used for sizes and poster frames; export and
            // merge still resolve media through RecordingPreviewService.
            let prefix = "recording-\(sessionFolderName)-\(String(format: "%02d", segment.index))"
            if let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in entries where entry.lastPathComponent.lowercased().hasPrefix(prefix) {
                    add(entry)
                }
            }
        }

        return urls.sorted { $0.path < $1.path }
    }

    private func fileSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return 0
        }
        if values.isDirectory == true {
            guard
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { return 0 }
            var total: Int64 = 0
            for case let child as URL in enumerator {
                guard
                    let childValues = try? child.resourceValues(
                        forKeys: [.isRegularFileKey, .fileSizeKey]
                    ), childValues.isRegularFile == true
                else { continue }
                total += Int64(childValues.fileSize ?? 0)
            }
            return total
        }
        return Int64(values.fileSize ?? 0)
    }
}
