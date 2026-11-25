import CaptureCore
import Foundation
import OSLog

/// Finds, adopts, and discards interrupted recordings that still have media on disk.
///
/// Scanning is read-only and safe to run at launch. Adoption only happens when the
/// user asks for it, and it journals a reference to the existing media instead of
/// copying or re-encoding anything. Discarding moves the session folder to the
/// Trash so the action stays reversible until the Trash is emptied.
actor RecordingRecoveryService {
    /// Shared instance used by the app; tests create their own.
    static let shared = RecordingRecoveryService()

    /// Readable failures surfaced to the recordings window.
    enum ServiceError: Error, Equatable, Sendable {
        /// The session folder is gone or was replaced by another path.
        case sessionUnavailable
        /// The journal cannot be replayed (hash chain or schema).
        case journalUnreadable
        /// The session has no media this build can reference in place.
        case noUsableMedia
        /// Segment index 0 is already published or publishing.
        case segmentConflict
        /// Moving the folder to the Trash failed.
        case discardFailed
    }

    private let logger = Logger(subsystem: "com.snapglass", category: "recording.recovery")
    private var scanRoots: [RecordingExportRoot] = []

    /// Scans every configured root and merges duplicate session IDs.
    ///
    /// - Parameter roots: Roots to scan; defaults to the app's current recording folders.
    /// - Returns: Recoverable sessions, newest first.
    @discardableResult
    func scan(roots: [RecordingExportRoot]? = nil) async -> [RecoverableRecording] {
        let roots = roots ?? RecordingExportRoots.current(in: .standard)
        scanRoots = roots
        var byID: [UUID: (recording: RecoverableRecording, root: RecordingExportRoot)] = [:]
        for root in roots where isDirectory(root.root) {
            // The catalog builds its own file manager, so no non-Sendable value
            // crosses the actor boundary here.
            let found = await RecordingRecoveryCatalog.scan(recordingRoot: root.root)
            for recording in found {
                if let existing = byID[recording.id] {
                    // The same session can exist in two configured folders.
                    if recording.createdAt > existing.recording.createdAt {
                        byID[recording.id] = (recording, root)
                    }
                } else {
                    byID[recording.id] = (recording, root)
                }
            }
        }
        let merged: [RecoverableRecording] = byID.values
            .map { $0.recording }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt > rhs.createdAt
            }
        logger.notice("recovery scan found \(merged.count, privacy: .public) recoverable session(s)")
        return merged
    }

    /// Adopts one interrupted session into the index of its own root.
    ///
    /// The session folder is kept exactly where it is: a failure leaves both the
    /// media and the journal untouched.
    ///
    /// - Parameter recording: Session chosen by the user.
    /// - Returns: The session record the list will now show.
    func recover(_ recording: RecoverableRecording) async throws -> RecordingSessionRecord {
        let root = try resolveRoot(for: recording)
        do {
            let record = try await RecordingRecoveryAdoption.adopt(
                recording,
                recordingRoot: root.root,
                indexURL: root.indexURL
            )
            logger.notice("recovery adopted session \(recording.id.uuidString, privacy: .public)")
            return record
        } catch let error as RecordingRecoveryAdoptionError {
            logger.error("recovery adopt failed: \(String(describing: error), privacy: .public)")
            throw Self.map(error)
        } catch {
            logger.error("recovery adopt failed unexpectedly: \(String(describing: error), privacy: .public)")
            throw ServiceError.journalUnreadable
        }
    }

    /// Moves one interrupted session folder to the Trash.
    ///
    /// Nothing is deleted permanently and no other session is touched.
    ///
    /// - Parameter recording: Session chosen by the user.
    func discard(_ recording: RecoverableRecording) async throws {
        let root = try resolveRoot(for: recording)
        let directory = Self.sessionDirectory(recording: recording, root: root)
        guard isDirectory(directory) else { throw ServiceError.sessionUnavailable }
        do {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        } catch {
            logger.error("recovery discard failed: \(String(describing: error), privacy: .public)")
            throw ServiceError.discardFailed
        }
        logger.notice("recovery moved session \(recording.id.uuidString, privacy: .public) to the Trash")
    }

    // MARK: Roots

    private func resolveRoot(for recording: RecoverableRecording) throws -> RecordingExportRoot {
        for root in scanRoots {
            let directory = Self.sessionDirectory(recording: recording, root: root)
            if isDirectory(directory) { return root }
        }
        // Fall back to the root implied by the scanned media path, so a recovery
        // still works when the folder list changed between scan and action.
        if let material = recording.materials.first {
            let sessionsDirectory = material
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if sessionsDirectory.lastPathComponent == ".SnapGlassSessions" {
                let kind: RecordingKind = recording.kind == .audio ? .audio : .screen
                let root = RecordingExportRoot(
                    kind: kind,
                    root: sessionsDirectory.deletingLastPathComponent()
                )
                if isDirectory(Self.sessionDirectory(recording: recording, root: root)) {
                    return root
                }
            }
        }
        throw ServiceError.sessionUnavailable
    }

    private static func sessionDirectory(
        recording: RecoverableRecording,
        root: RecordingExportRoot
    ) -> URL {
        root.root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(recording.id.uuidString.lowercased(), isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func map(_ error: RecordingRecoveryAdoptionError) -> ServiceError {
        switch error {
        case .sessionUnavailable: .sessionUnavailable
        case .journalUnreadable: .journalUnreadable
        case .noUsableMedia: .noUsableMedia
        case .segmentConflict: .segmentConflict
        }
    }
}
