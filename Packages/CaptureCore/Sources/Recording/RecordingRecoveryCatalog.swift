import AVFoundation
import Foundation

/// One interrupted recording whose media still exists on disk.
///
/// The catalog is a pure read: it never writes, moves, or deletes anything. It
/// exists because the journal-driven ``RecordingSessionLedger/recoverableSessions(in:indexURL:fileManager:)``
/// projection cannot see sessions that stopped before their first checkpoint —
/// a register-only session returns no recoverable segment there even when a
/// multi-megabyte CAF is on disk.
public struct RecoverableRecording: Sendable, Hashable, Identifiable {
    /// What kind of media the session captured.
    public enum Kind: Sendable, Hashable {
        /// Audio-only capture.
        case audio
        /// Screen capture, usually with a video file.
        case screen
    }

    /// How far the session's journal got before it stopped.
    public enum Condition: Sendable, Hashable {
        /// The journal already recorded progress (a checkpoint, publish intent,
        /// or closed segment) but no publish.
        case interrupted
        /// Only the `register` line exists; media was written but never journaled.
        case unregistered
    }

    /// Session identity, taken from the session directory name.
    public let id: UUID
    /// Media kind resolved from the journal, else from the file extensions.
    public let kind: Kind
    /// How much of the journal survived.
    public let condition: Condition
    /// Journal start time, else the session directory's creation date.
    public let createdAt: Date
    /// Longest probed material duration in seconds, or `0` when probing failed.
    ///
    /// A zero duration means "unknown", not "empty": the caller must hide the
    /// duration rather than print `0:00`.
    public let duration: TimeInterval
    /// Non-empty media files that can be previewed and exported in place.
    public let materials: [URL]
    /// Bytes of media that exist but cannot be used (for example 0-byte files).
    public let discardedByteCount: Int64

    /// Creates one recoverable recording description.
    ///
    /// - Parameters:
    ///   - id: Session identity.
    ///   - kind: Resolved media kind.
    ///   - condition: How much of the journal survived.
    ///   - createdAt: Best-known session start time.
    ///   - duration: Longest probed material duration, or `0` when unknown.
    ///   - materials: Non-empty media files inside the session directory.
    ///   - discardedByteCount: Bytes of unusable media inside the session directory.
    public init(
        id: UUID,
        kind: Kind,
        condition: Condition,
        createdAt: Date,
        duration: TimeInterval,
        materials: [URL],
        discardedByteCount: Int64
    ) {
        self.id = id
        self.kind = kind
        self.condition = condition
        self.createdAt = createdAt
        self.duration = duration
        self.materials = materials
        self.discardedByteCount = discardedByteCount
    }
}

/// Read-only discovery of interrupted sessions under `<root>/.SnapGlassSessions/`.
public enum RecordingRecoveryCatalog {
    /// File extensions the catalog treats as recorded media.
    private static let audioExtensions: Set<String> = ["caf", "wav", "aif", "aiff", "m4a"]
    /// Video extensions the catalog treats as recorded media.
    private static let videoExtensions: Set<String> = ["mp4", "mov"]

    /// Scans one recording root for sessions with usable media but no publish.
    ///
    /// A single unreadable session never fails the scan and never hides the
    /// others: unreadable journals, unsupported schemas and I/O errors simply
    /// remove that one session from the result. Zero-byte media is never offered
    /// as recoverable, because there is nothing to save.
    ///
    /// - Parameters:
    ///   - recordingRoot: Root that contains `.SnapGlassSessions`.
    ///   - fileManager: File manager used for reads.
    /// - Returns: Recoverable sessions, newest first.
    public static func scan(
        recordingRoot: URL,
        fileManager: FileManager = .default
    ) async -> [RecoverableRecording] {
        guard let root = try? RecordingLedgerFileSystem.canonicalDirectory(recordingRoot, create: false) else {
            return []
        }
        let sessionsDirectory = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        guard RecordingLedgerFileSystem.isDirectory(sessionsDirectory),
            (try? RecordingLedgerFileSystem.validateNoSymlink(sessionsDirectory)) != nil,
            let children = try? fileManager.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: [.creationDateKey]
            )
        else { return [] }

        var recordings: [RecoverableRecording] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard RecordingLedgerFileSystem.isDirectory(child),
                (try? RecordingLedgerFileSystem.validateNoSymlink(child)) != nil,
                let sessionID = UUID(uuidString: child.lastPathComponent)
            else { continue }
            if let recording = await inspect(
                sessionID: sessionID,
                sessionRoot: child,
                fileManager: fileManager
            ) {
                recordings.append(recording)
            }
        }
        return recordings.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }

    // MARK: One session

    private static func inspect(
        sessionID: UUID,
        sessionRoot: URL,
        fileManager: FileManager
    ) async -> RecoverableRecording? {
        guard let journal = readJournal(sessionRoot: sessionRoot, fileManager: fileManager) else {
            // Unreadable or future-schema journal: skip this session only.
            return nil
        }
        guard !journal.hasPublication else { return nil }

        var materials: [URL] = []
        var discardedByteCount: Int64 = 0
        collectMedia(
            in: sessionRoot,
            depth: 0,
            fileManager: fileManager,
            into: &materials,
            discardedByteCount: &discardedByteCount
        )
        guard !materials.isEmpty else { return nil }

        let kind = journal.kind ?? inferredKind(from: materials)
        let duration = await longestDuration(of: materials)
        let createdAt =
            journal.startedAt
            ?? creationDate(of: sessionRoot, fileManager: fileManager)
        return RecoverableRecording(
            id: sessionID,
            kind: kind,
            condition: journal.hasProgress ? .interrupted : .unregistered,
            createdAt: createdAt,
            duration: duration,
            materials: materials,
            discardedByteCount: discardedByteCount
        )
    }

    /// Journal facts the catalog needs; `nil` means the journal cannot be trusted.
    private struct JournalSummary {
        let kind: RecoverableRecording.Kind?
        let startedAt: Date?
        let hasProgress: Bool
        let hasPublication: Bool
    }

    private static func readJournal(sessionRoot: URL, fileManager: FileManager) -> JournalSummary? {
        let journalURL = sessionRoot.appendingPathComponent("journal.ndjson")
        guard fileManager.fileExists(atPath: journalURL.path) else {
            // A crash before `register` still leaves media behind; it is recoverable.
            return JournalSummary(kind: nil, startedAt: nil, hasProgress: false, hasPublication: false)
        }
        guard (try? RecordingLedgerFileSystem.validateNoSymlink(journalURL)) != nil,
            let data = try? Data(contentsOf: journalURL),
            data.isEmpty || data.last == 0x0A
        else { return nil }

        var kind: RecoverableRecording.Kind?
        var startedAt: Date?
        var hasProgress = false
        var hasPublication = false
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let core = try? decoder.decode(JournalCoreProbe.self, from: Data(line)) else { return nil }
            guard core.core.schemaVersion <= 1 else { return nil }
            switch core.core.payload.kind {
            case "register":
                if let record = core.core.payload.record {
                    kind = record.kind == "audio" ? .audio : .screen
                    startedAt = record.startedAt
                }
            case "checkpoint", "screenCheckpoint", "publishIntent", "segmentClosed":
                hasProgress = true
            case "published", "adopted":
                hasPublication = true
            default:
                // Unknown payload kinds are only a problem for the ledger; the
                // catalog simply keeps scanning the remaining lines.
                break
            }
        }
        return JournalSummary(
            kind: kind,
            startedAt: startedAt,
            hasProgress: hasProgress,
            hasPublication: hasPublication
        )
    }

    // MARK: Media

    private static func collectMedia(
        in directory: URL,
        depth: Int,
        fileManager: FileManager,
        into materials: inout [URL],
        discardedByteCount: inout Int64
    ) {
        guard depth <= 3,
            let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
            )
        else { return }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            if RecordingLedgerFileSystem.isDirectory(child) {
                guard (try? RecordingLedgerFileSystem.validateNoSymlink(child)) != nil else { continue }
                collectMedia(
                    in: child,
                    depth: depth + 1,
                    fileManager: fileManager,
                    into: &materials,
                    discardedByteCount: &discardedByteCount
                )
                continue
            }
            let ext = child.pathExtension.lowercased()
            guard audioExtensions.contains(ext) || videoExtensions.contains(ext),
                RecordingLedgerFileSystem.isRegularFile(child)
            else { continue }
            let size =
                (try? fileManager.attributesOfItem(atPath: child.path)[.size] as? NSNumber)?
                .int64Value ?? 0
            // Zero-byte media is recorded as discarded (0 bytes of nothing to
            // save) and never offered as recoverable material.
            guard size > 0 else { continue }
            materials.append(child)
        }
    }

    private static func inferredKind(from materials: [URL]) -> RecoverableRecording.Kind {
        let hasAudio = materials.contains { audioExtensions.contains($0.pathExtension.lowercased()) }
        return hasAudio ? .audio : .screen
    }

    private static func creationDate(of url: URL, fileManager: FileManager) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
    }

    /// Longest material duration; tracks of one session run concurrently.
    private static func longestDuration(of materials: [URL]) async -> TimeInterval {
        var longest: TimeInterval = 0
        for material in materials {
            let duration = await duration(of: material)
            longest = max(longest, duration)
        }
        return longest
    }

    private static func duration(of url: URL) async -> TimeInterval {
        if audioExtensions.contains(url.pathExtension.lowercased()) {
            return audioDuration(of: url)
        }
        return await videoDuration(of: url)
    }

    /// Frame-accurate length of a PCM container, or `0` when it cannot be read.
    private static func audioDuration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    private static func videoDuration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }
}

/// Minimal shape of one journal line, decoded without trusting the hash chain.
private struct JournalCoreProbe: Decodable {
    let core: JournalCoreProbeCore
}

/// The `core` object of one journal line.
private struct JournalCoreProbeCore: Decodable {
    let schemaVersion: Int
    let payload: JournalCoreProbePayload
}

/// The payload of one journal line; only the fields the catalog needs.
private struct JournalCoreProbePayload: Decodable {
    let kind: String
    let record: JournalCoreProbeRecord?
}

/// The `register` record fields used to classify a session.
private struct JournalCoreProbeRecord: Decodable {
    let kind: String
    let startedAt: Date
}
