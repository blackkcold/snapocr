import AVFoundation
import Foundation

/// Why an interrupted recording could not be adopted into the index.
public enum RecordingRecoveryAdoptionError: Error, Equatable, Sendable {
    /// The session directory (or its journal) is no longer readable.
    case sessionUnavailable
    /// The journal rejects its hash chain or cannot be replayed.
    case journalUnreadable
    /// The session has no media this build can reference in place.
    case noUsableMedia
    /// Another segment already owns segment index 0.
    case segmentConflict
}

/// Turns an interrupted session into an ordinary index entry without touching media.
///
/// Adoption only journls metadata: it references the files the recorder already
/// wrote, so no byte is copied or re-encoded and the original folder stays the
/// single source of truth. The journal line is an `adopted` payload, which the
/// ledger projects into `publishedSessions` exactly like a normal publication.
public enum RecordingRecoveryAdoption {
    /// File extensions treated as audio material.
    private static let audioExtensions: Set<String> = ["caf", "wav", "aif", "aiff", "m4a"]
    /// File extensions treated as video material.
    private static let videoExtensions: Set<String> = ["mp4", "mov"]
    /// Session sample rate used by every recording path.
    private static let sessionSampleRate: Int64 = 48_000

    /// Adopts one recoverable recording into the index of its own root.
    ///
    /// - Parameters:
    ///   - recording: Catalog entry to adopt.
    ///   - recordingRoot: Root that contains the session's `.SnapGlassSessions`.
    ///   - indexURL: Index cache for that root; the journal stays authoritative.
    ///   - fileManager: File manager used for reads and journal writes.
    /// - Returns: The session record as the index now reports it.
    /// - Throws: ``RecordingRecoveryAdoptionError`` when the session cannot be adopted.
    public static func adopt(
        _ recording: RecoverableRecording,
        recordingRoot: URL,
        indexURL: URL,
        fileManager: FileManager = .default
    ) async throws -> RecordingSessionRecord {
        let root: URL
        do {
            root = try RecordingLedgerFileSystem.canonicalDirectory(recordingRoot, create: false)
        } catch {
            throw RecordingRecoveryAdoptionError.sessionUnavailable
        }

        let sessionRoot = root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(recording.id.uuidString.lowercased(), isDirectory: true)
        guard RecordingLedgerFileSystem.isDirectory(sessionRoot) else {
            throw RecordingRecoveryAdoptionError.sessionUnavailable
        }

        let ledger: RecordingSessionLedger
        do {
            ledger = try RecordingSessionLedger(
                sessionRoot: sessionRoot,
                indexURL: indexURL,
                sessionID: recording.id,
                fileManager: RecordingSendableFileManager(fileManager),
                now: { Date() },
                readOnly: false
            )
        } catch RecordingSessionLedgerError.journalCorrupt {
            throw RecordingRecoveryAdoptionError.journalUnreadable
        } catch {
            throw RecordingRecoveryAdoptionError.sessionUnavailable
        }

        if (try? await ledger.snapshot()) == nil {
            // No `register` line survived: adopt the media and register the kind
            // the catalog resolved, which is what a normal session would have done.
            do {
                try await ledger.register(RecordingSessionRecord(
                    id: recording.id,
                    kind: recording.kind == .audio ? .audio : .screen,
                    layout: recording.kind == .audio ? .mixed : .separateTracks,
                    startedAt: recording.createdAt,
                    segments: []
                ))
            } catch {
                throw RecordingRecoveryAdoptionError.journalUnreadable
            }
        }

        let plan = try materialPlan(recording: recording, sessionRoot: sessionRoot, fileManager: fileManager)
        let segment = PublishedSegment(
            id: UUID(),
            index: 0,
            files: plan.files,
            startSample: 0,
            sampleCount: plan.sampleCount,
            trackMap: Dictionary(uniqueKeysWithValues: plan.files.keys.map { ($0, 0) }),
            missingRanges: [],
            state: .published,
            videoURL: plan.videoURL,
            videoTrackIndex: plan.videoURL == nil ? nil : 0,
            materialURL: plan.materialURL
        )
        do {
            _ = try await ledger.adoptPublishedSegment(segment)
            return try await ledger.snapshot()
        } catch RecordingSessionLedgerError.idempotencyConflict {
            throw RecordingRecoveryAdoptionError.segmentConflict
        } catch {
            throw RecordingRecoveryAdoptionError.journalUnreadable
        }
    }

    // MARK: Material mapping

    private struct MaterialPlan {
        let files: [String: String]
        let sampleCount: Int64
        let materialURL: URL?
        let videoURL: URL?
    }

    private static func materialPlan(
        recording: RecoverableRecording,
        sessionRoot: URL,
        fileManager: FileManager
    ) throws -> MaterialPlan {
        var files: [String: String] = [:]
        var framesByRole: [String: Int64] = [:]
        var materialURL: URL?
        var videoURL: URL?

        for material in recording.materials {
            guard let relative = try? RecordingLedgerFileSystem.validateChild(material, under: sessionRoot),
                  RecordingLedgerFileSystem.isRegularFile(material)
            else { continue }
            let ext = material.pathExtension.lowercased()
            if videoExtensions.contains(ext) {
                if videoURL == nil { videoURL = material }
                continue
            }
            guard audioExtensions.contains(ext) else { continue }
            let role = role(forFileName: material.lastPathComponent) ?? .mixed
            let name = roleName(role)
            guard let frames = audioFrameCount(of: material), frames > 0 else { continue }
            // One file per track role. When a session journaled several chunks,
            // the longest one is adopted and the rest stay untouched on disk.
            if let existingFrames = framesByRole[name], existingFrames >= frames { continue }
            files[name] = relative
            framesByRole[name] = frames
            if materialURL == nil { materialURL = material }
        }

        if files.isEmpty, let videoURL, let relative = try? RecordingLedgerFileSystem
            .validateChild(videoURL, under: sessionRoot) {
            // A screen session whose only media is the video container mirrors a
            // normal screen publication: the video file is both video and audio.
            files["mixed"] = relative
            materialURL = videoURL
        }
        guard !files.isEmpty else { throw RecordingRecoveryAdoptionError.noUsableMedia }

        // Every track of one segment must be readable for the same range, so the
        // adopted span is the shortest chosen file.
        var sampleCount = framesByRole.values.min() ?? 0
        if sampleCount == 0, let videoURL {
            sampleCount = max(1, Int64((videoDuration(of: videoURL) * Double(sessionSampleRate)).rounded(.down)))
        }
        guard sampleCount > 0 else { throw RecordingRecoveryAdoptionError.noUsableMedia }
        return MaterialPlan(
            files: files,
            sampleCount: sampleCount,
            materialURL: materialURL ?? videoURL,
            videoURL: videoURL
        )
    }

    private static func role(forFileName name: String) -> RecordingTrackRole? {
        let token = name.split(separator: "-", maxSplits: 1).first.map(String.init)?.lowercased()
        switch token {
        case "mixed": return .mixed
        case "system": return .system
        case "mic", "microphone": return .microphone
        default: return nil
        }
    }

    private static func roleName(_ role: RecordingTrackRole) -> String {
        switch role {
        case .mixed: "mixed"
        case .system: "system"
        case .microphone: "microphone"
        }
    }

    /// Exact frame count of a PCM container, or `nil` when it cannot be decoded.
    private static func audioFrameCount(of url: URL) -> Int64? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Int64(file.length)
    }

    private static func videoDuration(of url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? asset.duration else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}
