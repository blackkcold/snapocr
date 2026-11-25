import CaptureCore
import Foundation

/// Recovery scenario: catalog scan, idempotent adoption, and the real export path.
///
/// Kept in its own file so `AgentRunner` stays within the project's file and type
/// length budgets.
extension AgentRunner {
    /// Scans an isolated root, adopts the interrupted session, and exports it.
    ///
    /// The run proves the real path end to end: catalog → adoption → the same
    /// `publishedSessions` list the window reads → the real export service. It
    /// never writes outside `--agent-root` and never copies media.
    func runRecovery(scenario: AgentScenario) async {
        guard var scan = await scanRecoverableSessions() else { return }
        scan.recovery.catalogDuration = scan.target.duration

        record("recoveryAdopt")
        let adoption = await adoptRecoverableSession(scan)
        scan.recovery = adoption.recovery
        guard adoption.adopted else {
            await finish(sessionResult: nil, artifacts: [], recovery: scan.recovery)
            return
        }
        record("recoveryAdopted")

        var artifacts: [AgentReport.Artifact] = []
        do {
            let export = try await exportRecoveredSession(scan.target, roots: scan.roots)
            scan.recovery.exportedPath = export.path
            scan.recovery.exportedDuration = export.duration
            artifacts = [export]
        } catch {
            errors.append("recovery export: \(String(reflecting: error))")
        }
        record("recoveryExported")

        await finish(sessionResult: nil, artifacts: artifacts, recovery: scan.recovery)
    }

    /// Scans the isolated root and picks the longest audio session to adopt.
    ///
    /// - Returns: The resolved inputs and the report facts built so far, or `nil`
    ///   when the run already finished because nothing was recoverable.
    private func scanRecoverableSessions() async -> RecoveryScan? {
        let recordingRoot = configuration.rootURL
        let exportRoots = [RecordingExportRoot(kind: .audio, root: recordingRoot)]
        let indexURL = exportRoots[0].indexURL
        let service = RecordingRecoveryService()

        record("recoveryScan")
        let scanned = await service.scan(roots: exportRoots)
        record("recoveryScanned")
        let zeroByteIDs = Self.zeroByteSessionIDs(root: recordingRoot)
        let scannedIDs = Set(scanned.map(\.id))
        let zeroByteVisible = !zeroByteIDs.isDisjoint(with: scannedIDs)
        let items = scanned.map { recording in
            AgentReport.RecoverableItem(
                id: recording.id.uuidString.lowercased(),
                kind: recording.kind == .audio ? "audio" : "screen",
                condition: recording.condition == .interrupted ? "interrupted" : "unregistered",
                durationSec: recording.duration,
                materials: recording.materials.map(\.path)
            )
        }
        let recovery = AgentReport.RecoveryFacts(
            scanned: scanned.count,
            recoverable: items,
            adopted: 0,
            publishedAfterRecovery: 0,
            catalogDuration: nil,
            exportedPath: nil,
            exportedDuration: nil,
            zeroByteSessions: zeroByteIDs.count,
            zeroByteVisible: zeroByteVisible,
            idempotent: false
        )

        guard let target = scanned
            .filter({ $0.kind == .audio })
            .max(by: { $0.duration < $1.duration })
        else {
            errors.append("recovery: no recoverable audio session found")
            await finish(sessionResult: nil, artifacts: [], recovery: recovery)
            return nil
        }
        return RecoveryScan(
            service: service,
            roots: exportRoots,
            indexURL: indexURL,
            recordingRoot: recordingRoot,
            target: target,
            recovery: recovery
        )
    }

    /// Adopts the target twice, proving the second recovery changes nothing.
    ///
    /// - Returns: The updated facts and whether the adoption succeeded. A failed
    ///   adoption still reports the facts gathered before the error.
    private func adoptRecoverableSession(
        _ scan: RecoveryScan
    ) async -> (recovery: AgentReport.RecoveryFacts, adopted: Bool) {
        var recovery = scan.recovery
        do {
            _ = try await scan.service.recover(scan.target)
            recovery.adopted += 1
            let afterFirst = try await RecordingSessionLedger.publishedSessions(
                in: scan.recordingRoot, indexURL: scan.indexURL
            )
            // Idempotency: a second recovery of the same session must not add a
            // second entry, and must not append a second journal line.
            let journalURL = Self.journalURL(root: scan.recordingRoot, sessionID: scan.target.id)
            let journalBefore = try? Data(contentsOf: journalURL)
            _ = try await scan.service.recover(scan.target)
            let afterSecond = try await RecordingSessionLedger.publishedSessions(
                in: scan.recordingRoot, indexURL: scan.indexURL
            )
            let journalAfter = try? Data(contentsOf: journalURL)
            recovery.publishedAfterRecovery = afterSecond.count
            recovery.idempotent = afterSecond.count == 1
                && afterFirst.count == afterSecond.count
                && journalBefore == journalAfter
            return (recovery, true)
        } catch {
            errors.append("recovery adopt: \(String(reflecting: error))")
            return (recovery, false)
        }
    }

    /// Exports an adopted session through the real view-model + export path.
    private func exportRecoveredSession(
        _ target: RecoverableRecording,
        roots: [RecordingExportRoot]
    ) async throws -> AgentReport.Artifact {
        let model = RecordingExportViewModel(roots: roots)
        await model.loadPublishedSessions()
        guard model.publishedSessions.contains(where: { $0.id == target.id }) else {
            throw RecoveryHarnessError.sessionNotListed
        }
        await model.selectSession(target.id)
        guard let session = model.session else { throw RecoveryHarnessError.sessionNotListed }
        model.setOutputDirectory(configuration.outputURL)
        model.setOutputStem("recovered-\(target.id.uuidString.lowercased().prefix(8))")
        for segment in session.segments where segment.state == .published {
            model.setSegmentSelected(segment.id, isSelected: true)
        }
        // Assessment runs off the main actor; wait for a validated plan.
        let deadline = clock.now.advanced(by: .seconds(20))
        while !model.canExport, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard model.canExport else {
            throw RecoveryHarnessError.exportUnavailable(
                String(describing: model.assess().disabledReason)
            )
        }
        let result = try await model.export()
        let duration = await mediaDuration(of: result.outputURL)
        return AgentReport.Artifact(
            path: result.outputURL.path,
            bytes: Self.fileSize(result.outputURL),
            duration: duration
        )
    }

    /// Session directories whose media is entirely zero bytes.
    private static func zeroByteSessionIDs(root: URL) -> Set<UUID> {
        let sessions = root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: nil
        ) else { return [] }
        let mediaExtensions: Set<String> = ["caf", "wav", "aif", "aiff", "m4a", "mp4", "mov"]
        var ids: Set<UUID> = []
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            var media: [URL] = []
            if let enumerator = FileManager.default.enumerator(
                at: child, includingPropertiesForKeys: [.isRegularFileKey]
            ) {
                for case let url as URL in enumerator
                where mediaExtensions.contains(url.pathExtension.lowercased()) {
                    media.append(url)
                }
            }
            guard !media.isEmpty else { continue }
            let allZero = media.allSatisfy { Self.fileSize($0) == 0 }
            if allZero { ids.insert(id) }
        }
        return ids
    }

    static func journalURL(root: URL, sessionID: UUID) -> URL {
        root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("journal.ndjson")
    }

    /// Counts durable checkpoint lines in a session journal.
    static func journalFacts(root: URL, sessionID: UUID) -> AgentReport.JournalFacts? {
        let url = journalURL(root: root, sessionID: sessionID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        var count = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let core = object["core"] as? [String: Any],
                  let payload = core["payload"] as? [String: Any],
                  let kind = payload["kind"] as? String
            else { continue }
            if kind == "checkpoint" { count += 1 }
        }
        return AgentReport.JournalFacts(
            path: url.path,
            checkpointCount: count,
            checkpointIntervalSeconds: RecordingSessionPipeline.checkpointIntervalSeconds
        )
    }
}

/// One recovery run's resolved inputs plus the report facts built so far.
private struct RecoveryScan {
    let service: RecordingRecoveryService
    let roots: [RecordingExportRoot]
    let indexURL: URL
    let recordingRoot: URL
    let target: RecoverableRecording
    var recovery: AgentReport.RecoveryFacts
}

/// Failures specific to the recovery harness itself.
private enum RecoveryHarnessError: Error {
    case sessionNotListed
    case exportUnavailable(String)
}
