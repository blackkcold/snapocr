import AVFoundation
import CaptureCore
import Foundation
import LibraryCore

/// Headless, non-destructive CLI for the unified library.
///
/// It is intentionally built as a separate Xcode tool target: the product app
/// never ships this executable, and automation never touches the user library
/// unless the caller passes an explicit root.
@main
struct SnapGlassLibraryCLI {
    static func main() async {
        do {
            let output = try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            FileHandle.standardOutput.write(Data(output.utf8))
        } catch {
            let message = "error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func run(arguments: [String]) async throws -> String {
        var args = arguments
        guard !args.isEmpty else {
            return usage()
        }
        let command = args.removeFirst()
        var rootPath: String?
        var sessionID: UUID?
        var destinationPath: String?
        var title: String?
        var json = false
        var media = false
        var screenshots = 1_000
        var recordings = 200
        var mediaCount = 10
        var assertBudgets = false
        var keepBench = false

        var index = 0
        while index < args.count {
            switch args[index] {
            case "--root":
                index += 1
                rootPath = args[safe: index]
            case "--session":
                index += 1
                sessionID = args[safe: index].flatMap(UUID.init(uuidString:))
            case "--dest":
                index += 1
                destinationPath = args[safe: index]
            case "--title":
                index += 1
                title = args[safe: index]
            case "--json":
                json = true
            case "--media":
                media = true
            case "--screenshots":
                index += 1
                screenshots = args[safe: index].flatMap(Int.init) ?? screenshots
            case "--recordings":
                index += 1
                recordings = args[safe: index].flatMap(Int.init) ?? recordings
            case "--media-count":
                index += 1
                mediaCount = args[safe: index].flatMap(Int.init) ?? mediaCount
            case "--assert":
                assertBudgets = true
            case "--keep":
                keepBench = true
            default:
                break
            }
            index += 1
        }

        if command == "help" || command == "--help" {
            return usage()
        }

        guard let rootPath, !rootPath.isEmpty else {
            throw CLIError.missingRoot
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let metadataURL = root
            .appendingPathComponent(".snapglass-cli", isDirectory: true)
            .appendingPathComponent(RecordingLibraryStore.defaultFileName)
        let metadataStore = RecordingLibraryStore(fileURL: metadataURL)
        let roots = [LibraryRoot(kind: .screen, root: root)]
        let library = RecordingLibraryService(roots: roots, metadataStore: metadataStore)

        switch command {
        case "scan":
            let snapshot = await library.scan()
            return try encode(
                [
                    "ok": true,
                    "command": "scan",
                    "root": root.path,
                    "sessions": snapshot.groups.count,
                    "bytes": snapshot.totalBytes,
                    "offlineRoots": snapshot.offlineRoots,
                    "items": snapshot.groups.map { group in
                        [
                            "session": group.sessionID.uuidString,
                            "kind": group.kind == .audio ? "audio" : "video",
                            "title": group.title,
                            "duration": group.duration,
                            "segments": group.segmentCount,
                            "state": status(group),
                        ] as [String: Any]
                    },
                ],
                json: json
            )

        case "export":
            guard let sessionID, let destinationPath else {
                throw CLIError.missingSessionOrDestination
            }
            let snapshot = await library.scan()
            guard let group = snapshot.groups.first(where: { $0.sessionID == sessionID }) else {
                throw CLIError.sessionNotFound
            }
            let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let exporter = LibraryExportService()
            let result = try await exporter.export(
                items: [.recording(group)],
                options: LibraryExportOptions(
                    destination: destination,
                    layout: .byType,
                    includeManifest: true
                ),
                progress: { _ in }
            )
            return try encode(
                [
                    "ok": result.failures.isEmpty,
                    "command": "export",
                    "outputs": result.outputURLs.map(\.path),
                    "manifest": result.manifestURL?.path ?? NSNull(),
                    "failures": result.failures,
                ],
                json: json
            )

        case "merge":
            guard let sessionID, let destinationPath else {
                throw CLIError.missingSessionOrDestination
            }
            let snapshot = await library.scan()
            guard let group = snapshot.groups.first(where: { $0.sessionID == sessionID }) else {
                throw CLIError.sessionNotFound
            }
            let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let merger = RecordingMergeService()
            let result = try await merger.merge(
                group: group,
                destination: destination,
                outputTitle: title ?? "Merged Recording",
                progress: { _ in }
            )
            return try encode(
                [
                    "ok": true,
                    "command": "merge",
                    "outputs": result.outputURLs.map(\.path),
                    "duration": result.totalDuration,
                ],
                json: json
            )

        case "delete":
            guard let sessionID else {
                throw CLIError.missingSession
            }
            let snapshot = await library.scan()
            guard let group = snapshot.groups.first(where: { $0.sessionID == sessionID }) else {
                throw CLIError.sessionNotFound
            }
            let deletion = RecordingDeletionService(metadataStore: metadataStore)
            let report = await deletion.delete(group)
            return try encode(
                [
                    "ok": report.failures.isEmpty,
                    "command": "delete",
                    "deleted": report.deletedSessionCount,
                    "trashed": report.trashedURLs.map(\.path),
                    "failures": report.failures,
                ],
                json: json
            )

        case "bench":
            return try await LibraryBench.run(
                options: LibraryBench.Options(
                    root: root,
                    screenshots: max(1, screenshots),
                    recordings: max(0, recordings),
                    mediaCount: max(0, mediaCount),
                    assertBudgets: assertBudgets,
                    keep: keepBench
                )
            )

        case "l10n-check":
            return try LibraryL10nCheck.run(projectRoot: root)

        case "selftest":
            return try await selfTest(
                root: root,
                metadataStore: metadataStore,
                media: media
            )

        case "help", "--help":
            return usage()

        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func selfTest(
        root: URL,
        metadataStore: RecordingLibraryStore,
        media: Bool
    ) async throws -> String {
        let sessionID = UUID()
        await metadataStore.setDisplayName("CLI Self Test", for: sessionID)
        await metadataStore.setFavourite(true, for: sessionID)
        await metadataStore.saveNow()
        let entry = await metadataStore.entry(for: sessionID)
        let metadataOK = entry.displayName == "CLI Self Test" && entry.isFavourite
        let parts = MergePartPlanner.parts(
            segmentDurations: [3_540, 3_540, 3_540],
            maximumDuration: RecordingExportPlanner.maximumExportDuration
        )
        let plannerOK = parts.count == 2 && parts[0].segmentIndices == [0, 1]

        var mediaOK = true
        var mediaDuration: Double = 0
        var mediaOutput: String?
        if media {
            let result = try await runMediaSelfTest(under: root)
            mediaOK = result.isOK
            mediaDuration = result.duration
            mediaOutput = result.output
        }

        let isOK = metadataOK && plannerOK && mediaOK
        var object: [String: Any] = [
            "ok": isOK,
            "command": "selftest",
            "root": root.path,
            "metadata": metadataOK,
            "mergePlanner": plannerOK,
            "parts": parts.count,
            "media": mediaOK,
        ]
        if media {
            object["mediaDuration"] = mediaDuration
            object["mediaOutput"] = mediaOutput ?? NSNull()
        }
        return try encode(object, json: true)
    }

    private struct MediaSelfTestResult {
        let isOK: Bool
        let duration: Double
        let output: String?
    }

    private static func runMediaSelfTest(under root: URL) async throws -> MediaSelfTestResult {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(
            ".media-selftest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let firstCAF = try writeSilentCAF(
            at: directory.appendingPathComponent("first.caf")
        )
        let secondCAF = try writeSilentCAF(
            at: directory.appendingPathComponent("second.caf")
        )
        let firstPlan = try makePlan(
            caf: firstCAF,
            outputDirectory: outputDirectory,
            stem: "first"
        )
        let secondPlan = try makePlan(
            caf: secondCAF,
            outputDirectory: outputDirectory,
            stem: "second"
        )
        let merged = try RecordingPlanMerger.merge(
            [firstPlan, secondPlan],
            sessionID: firstPlan.sessionID,
            destination: ExportDestination(
                directory: outputDirectory,
                stem: "selftest"
            ),
            outputSpec: firstPlan.outputSpec
        )
        let result = try await RecordingCompositionExporter().export(merged) { _ in }
        let asset = AVURLAsset(url: result.outputURL)
        let duration = CMTimeGetSeconds(asset.duration)
        let isOK = fileManager.fileExists(atPath: result.outputURL.path) && duration > 1.5
        return MediaSelfTestResult(
            isOK: isOK,
            duration: duration,
            output: result.outputURL.path
        )
    }

    private static func makePlan(
        caf: URL,
        outputDirectory: URL,
        stem: String
    ) throws -> ExportPlan {
        let segmentID = UUID()
        let sessionID = UUID()
        let segment = PublishedSegment(
            id: segmentID,
            index: 0,
            files: ["mixed": caf.lastPathComponent],
            startSample: 0,
            sampleCount: 48_000,
            trackMap: ["mixed": 0],
            missingRanges: [],
            state: .published,
            videoURL: nil,
            videoTrackIndex: nil,
            materialURL: caf
        )
        let session = RecordingSessionRecord(
            id: sessionID,
            kind: .audio,
            layout: .mixed,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            segments: [segment]
        )
        let selection = ExportSelection(
            segmentIDs: [segmentID],
            includeVideo: false,
            destination: ExportDestination(
                directory: outputDirectory,
                stem: stem
            )
        )
        return try RecordingExportPlanner.plan(
            session: session,
            selection: selection,
            audioSourcesBySegment: [segmentID: .recoveredMedia([caf])]
        )
    }

    private static func writeSilentCAF(at url: URL) throws -> URL {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        ) else {
            throw CLIError.mediaFixture("audio format unavailable")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 48_000
        ) else {
            throw CLIError.mediaFixture("audio buffer unavailable")
        }
        buffer.frameLength = 48_000
        try file.write(from: buffer)
        return url
    }

    private static func status(_ group: LibraryRecordingGroup) -> String {
        switch group.state {
        case .complete: return "complete"
        case .partial(let missing): return "partial(\(missing))"
        case .offline: return "offline"
        }
    }

    private static func encode(_ object: [String: Any], json: Bool) throws -> String {
        guard json else {
            return object
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: "\n") + "\n"
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private static func usage() -> String {
        """
        snapglass-library <command> --root <dir> [options]

        Commands:
          scan      Scan a recording root and print sessions
          export    Export one session as original files
          merge     Merge one session's segments
          delete    Move one session to the Trash
          selftest  Verify metadata + merge planning; --media runs a real CAF merge
          bench     1000/200 headless benchmark; --assert gates budgets
          l10n-check Validate key/placeholder/glossary/width for four languages
          help      Show this help

        Options:
          --session <uuid>   Session to act on
          --dest <dir>       Export destination
          --title <string>   Merge output title
          --screenshots <n>  Benchmark screenshot count (default 1000)
          --recordings <n>   Benchmark recording count (default 200)
          --media-count <n>  Benchmark real CAF merge count (default 10)
          --assert           Fail on benchmark budget overrun
          --keep             Keep benchmark fixtures
          --media            Run the real-media self-test
          --json             Machine-readable JSON
        """
    }
}

private enum CLIError: Error, LocalizedError {
    case missingRoot
    case missingSession
    case missingSessionOrDestination
    case sessionNotFound
    case unknownCommand(String)
    case mediaFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingRoot: return "--root is required"
        case .missingSession: return "--session is required"
        case .missingSessionOrDestination: return "--session and --dest are required"
        case .sessionNotFound: return "session not found in the given root"
        case .unknownCommand(let command): return "unknown command: \(command)"
        case .mediaFixture(let reason): return "media self-test fixture failed: \(reason)"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
