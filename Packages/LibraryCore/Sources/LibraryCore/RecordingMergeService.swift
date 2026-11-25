import CaptureCore
import Foundation
import LibraryCore
import OSLog

public enum RecordingMergeError: Error, LocalizedError {
    case noRoot
    case sessionUnavailable
    case noPublishedSegments
    case disabled(ExportDisabledReason)
    case overLimit
    case mixedKinds
    case cancelled
    case export(ExportError)

    public var errorDescription: String? {
        switch self {
        case .noRoot:
            return LibraryLocalization.string("The recording folder is offline.")
        case .sessionUnavailable:
            return LibraryLocalization.string("This recording is no longer available.")
        case .noPublishedSegments:
            return LibraryLocalization.string("This recording has no published segments to merge.")
        case .disabled(let reason):
            switch reason {
            case .emptySelection:
                return LibraryLocalization.string("Choose at least one segment to merge.")
            case .overLimit(let seconds):
                return LibraryLocalization.string("The merge exceeds the file limit by %@.", Self.duration(seconds))
            case .incompatibleCodec:
                return LibraryLocalization.string("The selected segments use incompatible codecs.")
            case .missingSource:
                return LibraryLocalization.string("A selected segment is missing.")
            case .destinationUnavailable:
                return LibraryLocalization.string("Choose an existing writable destination folder.")
            case .passthroughUnsupported:
                return LibraryLocalization.string("This recording cannot be merged without re-encoding.")
            }
        case .overLimit:
            return LibraryLocalization.string("A single segment is longer than the 1:59:30 file limit.")
        case .mixedKinds:
            return LibraryLocalization.string("Only recordings of the same type can be merged together.")
        case .cancelled:
            return LibraryLocalization.string("Merge cancelled. The original recording was kept.")
        case .export(let error):
            return error.localizedDescription
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        formatter.maximumUnitCount = 3
        return formatter.string(from: max(0, seconds)) ?? "0:00"
    }
}

public struct RecordingMergeResult: Sendable {
    public let outputURLs: [URL]
    public let totalDuration: TimeInterval
}

/// Merges the published segments of one session into one or more files.
///
/// The merge is an export: source segments are never deleted. Segments are
/// leased through `RecordingPreviewService` so the journal remains the only
/// source of truth, and the existing composition exporter performs the actual
/// concatenation.
public actor RecordingMergeService {
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.snapglass.app", category: "RecordingMerge")

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func merge(
        group: LibraryRecordingGroup,
        destination: URL,
        outputTitle: String,
        progress: @escaping @Sendable (LibraryExportProgress) -> Void
    ) async throws -> RecordingMergeResult {
        guard let root = group.roots.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw RecordingMergeError.noRoot
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let indexURL = root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")

        let record: RecordingSessionRecord
        do {
            let ledger = try await RecordingSessionLedger.openExisting(
                sessionID: group.sessionID,
                recordingRoot: root,
                indexURL: indexURL
            )
            record = try await ledger.snapshot()
        } catch {
            logger.error("Could not open session: \(error.localizedDescription, privacy: .public)")
            throw RecordingMergeError.sessionUnavailable
        }

        let published = record.segments
            .filter { $0.state == .published }
            .sorted { lhs, rhs in
                if lhs.index == rhs.index { return lhs.startSample < rhs.startSample }
                return lhs.index < rhs.index
            }
        guard !published.isEmpty else { throw RecordingMergeError.noPublishedSegments }

        let durations = published.map { Double(max(0, $0.sampleCount)) / 48_000 }
        let parts = MergePartPlanner.parts(
            segmentDurations: durations,
            maximumDuration: RecordingExportPlanner.maximumExportDuration
        )
        guard !parts.contains(where: \.isOverLimit) else {
            throw RecordingMergeError.overLimit
        }

        let previewService: RecordingPreviewService
        do {
            let ledger = try await RecordingSessionLedger.openExisting(
                sessionID: group.sessionID,
                recordingRoot: root,
                indexURL: indexURL
            )
            previewService = await ledger.makePreviewService()
        } catch {
            throw RecordingMergeError.sessionUnavailable
        }

        var leases: [UUID: PreviewLease] = [:]
        var sources: [UUID: ExportAudioSource] = [:]
        do {
            for segment in published {
                let lease = try await previewService.leasePreview(
                    for: segment.id,
                    duration: 24 * 60 * 60
                )
                leases[segment.id] = lease
                sources[segment.id] = segment.materialURL == nil
                    ? .publishedMedia(lease.mediaURLs)
                    : .recoveredMedia(lease.mediaURLs)
            }
        } catch {
            await release(leases.values, using: previewService)
            throw RecordingMergeError.sessionUnavailable
        }

        var outputs: [URL] = []
        do {
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let partSegments = part.segmentIndices.compactMap { published.indices.contains($0) ? published[$0] : nil }
                let segmentIDs = partSegments.map(\.id)
                let stem = mergeStem(
                    title: outputTitle,
                    partIndex: parts.count > 1 ? index + 1 : nil
                )
                let selection = ExportSelection(
                    segmentIDs: segmentIDs,
                    trackSelection: .mixed,
                    includeVideo: group.kind == .screen,
                    audioGainDB: 0,
                    destination: ExportDestination(directory: destination, stem: stem)
                )

                let assessment = RecordingExportPlanner.assess(
                    session: record,
                    selection: selection,
                    audioSourcesBySegment: sources
                )
                if let disabled = assessment.disabledReason {
                    throw RecordingMergeError.disabled(disabled)
                }

                let plan = try RecordingExportPlanner.plan(
                    session: record,
                    selection: selection,
                    audioSourcesBySegment: sources
                )
                let exporter = RecordingCompositionExporter()
                let result = try await exporter.export(plan) { exportProgress in
                    let base = Double(index) / Double(parts.count)
                    let slice = exportProgress.fraction / Double(parts.count)
                    progress(
                        LibraryExportProgress(
                            fraction: min(1, base + slice),
                            message: LibraryLocalization.string("Merging part %@ of %@…", String(index + 1), String(parts.count))
                        )
                    )
                }

                let finalURL = uniqueURL(
                    destination.appendingPathComponent(
                        "\(stem).\(result.outputURL.pathExtension)"
                    )
                )
                try fileManager.moveItem(at: result.outputURL, to: finalURL)
                outputs.append(finalURL)
            }
        } catch let error as ExportError {
            if case .cancelled(let stagingURL) = error, let stagingURL {
                try? fileManager.removeItem(at: stagingURL)
            }
            await release(leases.values, using: previewService)
            if case .cancelled = error { throw RecordingMergeError.cancelled }
            throw RecordingMergeError.export(error)
        } catch {
            await release(leases.values, using: previewService)
            throw error
        }

        await release(leases.values, using: previewService)
        return RecordingMergeResult(
            outputURLs: outputs,
            totalDuration: durations.reduce(0, +)
        )
    }

    // MARK: - Cross-session merge

    public func merge(
        groups: [LibraryRecordingGroup],
        destination: URL,
        outputTitle: String,
        progress: @escaping @Sendable (LibraryExportProgress) -> Void
    ) async throws -> RecordingMergeResult {
        guard let first = groups.first else { throw RecordingMergeError.noPublishedSegments }
        guard groups.allSatisfy({ $0.kind == first.kind }) else {
            throw RecordingMergeError.mixedKinds
        }
        if groups.count == 1 {
            return try await merge(
                group: first,
                destination: destination,
                outputTitle: outputTitle,
                progress: progress
            )
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var plans: [GroupMergePlan] = []
        do {
            for group in groups {
                plans.append(try await makeGroupPlan(for: group, destination: destination))
            }
        } catch {
            await release(plans)
            throw error
        }

        let totalDuration = plans.reduce(0) { $0 + $1.plan.estimatedDuration }
        guard totalDuration <= RecordingExportPlanner.maximumExportDuration else {
            await release(plans)
            throw RecordingMergeError.overLimit
        }

        do {
            let merged = try RecordingPlanMerger.merge(
                plans.map(\.plan),
                sessionID: first.sessionID,
                destination: ExportDestination(
                    directory: destination,
                    stem: sanitized(outputTitle)
                ),
                outputSpec: plans[0].plan.outputSpec
            )
            let exporter = RecordingCompositionExporter()
            let result = try await exporter.export(merged) { exportProgress in
                progress(
                    LibraryExportProgress(
                        fraction: exportProgress.fraction,
                        message: LibraryLocalization.string("Merging recordings…")
                    )
                )
            }
            let finalURL = uniqueURL(
                destination.appendingPathComponent(
                    "\(sanitized(outputTitle)).\(result.outputURL.pathExtension)"
                )
            )
            try fileManager.moveItem(at: result.outputURL, to: finalURL)
            await release(plans)
            return RecordingMergeResult(
                outputURLs: [finalURL],
                totalDuration: totalDuration
            )
        } catch let error as ExportError {
            if case .cancelled(let stagingURL) = error, let stagingURL {
                try? fileManager.removeItem(at: stagingURL)
            }
            await release(plans)
            if case .cancelled = error { throw RecordingMergeError.cancelled }
            throw RecordingMergeError.export(error)
        } catch {
            await release(plans)
            throw error
        }
    }

    private struct GroupMergePlan {
        let plan: ExportPlan
        let service: RecordingPreviewService
        let leases: [PreviewLease]
    }

    private func makeGroupPlan(
        for group: LibraryRecordingGroup,
        destination: URL
    ) async throws -> GroupMergePlan {
        guard let root = group.roots.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw RecordingMergeError.noRoot
        }
        let indexURL = root
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")

        let record: RecordingSessionRecord
        do {
            let ledger = try await RecordingSessionLedger.openExisting(
                sessionID: group.sessionID,
                recordingRoot: root,
                indexURL: indexURL
            )
            record = try await ledger.snapshot()
        } catch {
            throw RecordingMergeError.sessionUnavailable
        }

        let published = record.segments
            .filter { $0.state == .published }
            .sorted { $0.index < $1.index }
        guard !published.isEmpty else { throw RecordingMergeError.noPublishedSegments }

        let previewService: RecordingPreviewService
        do {
            let ledger = try await RecordingSessionLedger.openExisting(
                sessionID: group.sessionID,
                recordingRoot: root,
                indexURL: indexURL
            )
            previewService = await ledger.makePreviewService()
        } catch {
            throw RecordingMergeError.sessionUnavailable
        }

        var leases: [PreviewLease] = []
        var sources: [UUID: ExportAudioSource] = [:]
        do {
            for segment in published {
                let lease = try await previewService.leasePreview(
                    for: segment.id,
                    duration: 24 * 60 * 60
                )
                leases.append(lease)
                sources[segment.id] = segment.materialURL == nil
                    ? .publishedMedia(lease.mediaURLs)
                    : .recoveredMedia(lease.mediaURLs)
            }
        } catch {
            for lease in leases { await previewService.release(lease) }
            throw RecordingMergeError.sessionUnavailable
        }

        let selection = ExportSelection(
            segmentIDs: published.map(\.id),
            trackSelection: .mixed,
            includeVideo: group.kind == .screen,
            audioGainDB: 0,
            destination: ExportDestination(
                directory: destination,
                stem: "merge-\(group.sessionID.uuidString.prefix(8))"
            )
        )
        let assessment = RecordingExportPlanner.assess(
            session: record,
            selection: selection,
            audioSourcesBySegment: sources
        )
        if let disabled = assessment.disabledReason {
            for lease in leases { await previewService.release(lease) }
            throw RecordingMergeError.disabled(disabled)
        }

        do {
            let plan = try RecordingExportPlanner.plan(
                session: record,
                selection: selection,
                audioSourcesBySegment: sources
            )
            return GroupMergePlan(plan: plan, service: previewService, leases: leases)
        } catch let error as ExportError {
            for lease in leases { await previewService.release(lease) }
            throw RecordingMergeError.export(error)
        } catch {
            for lease in leases { await previewService.release(lease) }
            throw error
        }
    }

    private func release(_ plans: [GroupMergePlan]) async {
        for plan in plans {
            for lease in plan.leases {
                await plan.service.release(lease)
            }
        }
    }

    private func release(
        _ leases: Dictionary<UUID, PreviewLease>.Values,
        using service: RecordingPreviewService
    ) async {
        for lease in leases {
            await service.release(lease)
        }
    }

    private func mergeStem(title: String, partIndex: Int?) -> String {
        let base = sanitized(title)
        guard let partIndex else { return base }
        return "\(base)-part\(String(format: "%02d", partIndex))"
    }

    private func sanitized(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var value = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = LibraryLocalization.string("Merged Recording") }
        return String(value.prefix(80))
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
}
