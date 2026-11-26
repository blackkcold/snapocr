import AVFoundation
import CaptureCore
import CoreGraphics
import Darwin
import Foundation
import HistoryCore
import LibraryCore

/// Headless benchmark harness for the unified library.
///
/// Fixtures are generated in an isolated subdirectory; no GUI is launched and
/// the user's library is never read. Output is a machine-readable JSON report.
enum LibraryBench {
    struct Options {
        var root: URL
        var screenshots: Int
        var recordings: Int
        var mediaCount: Int
        var assertBudgets: Bool
        var keep: Bool
    }

    struct Budgets {
        var coldPageMs: Double = 2_000
        var warmPageMs: Double = 300
        var searchMs: Double = 500
        var scanMs: Double = 1_500
        var thumbnailMs: Double = 5_000
        var mediaMs: Double = 5_000
        var rssMB: Double = 250
    }

    /// Screenshot/history timings, in the order they were measured.
    private struct ScreenshotMetrics {
        var generationMs: Double
        var coldPageMs: Double
        var warmPageMs: Double
        var searchMs: Double
        var thumbnailMs: Double
        var rssMB: Double
        var pageCount: Int
    }

    /// Recording-root scan timings.
    private struct RecordingMetrics {
        var scanMs: Double
        var groups: Int
    }

    /// Real CAF merge timings and output size.
    private struct MediaMetrics {
        var mergeMs: Double
        var bytes: Int64
        var duration: Double
    }

    /// Every measurement plus the thresholds it is compared against.
    private struct Measurement {
        var budgets: Budgets
        var screenshots: ScreenshotMetrics
        var recordings: RecordingMetrics
        var media: MediaMetrics
    }

    static func run(options: Options) async throws -> String {
        let fileManager = FileManager.default
        let benchRoot = options.root.appendingPathComponent(
            "bench-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: benchRoot, withIntermediateDirectories: true)
        defer {
            if !options.keep {
                try? fileManager.removeItem(at: benchRoot)
            }
        }

        let screenshots = try await runScreenshotBench(
            options: options,
            benchRoot: benchRoot
        )
        let recordings = try await runRecordingBench(
            options: options,
            benchRoot: benchRoot,
            fileManager: fileManager
        )
        let media = try await runMediaBench(
            options: options,
            benchRoot: benchRoot,
            fileManager: fileManager
        )

        let measurement = Measurement(
            budgets: Budgets(),
            screenshots: screenshots,
            recordings: recordings,
            media: media
        )
        let failures = evaluateBudgets(measurement: measurement, options: options)
        let report = makeReport(
            benchRoot: benchRoot,
            options: options,
            measurement: measurement,
            failures: failures
        )
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    // MARK: - Screenshot benchmark

    private static func runScreenshotBench(
        options: Options,
        benchRoot: URL
    ) async throws -> ScreenshotMetrics {
        let screenshotRoot = benchRoot.appendingPathComponent("screenshots", isDirectory: true)
        let cleanup = CleanupPolicy(
            maxEntries: max(options.screenshots + 500, 2_000),
            maxTotalSizeBytes: 2 * 1_024 * 1_024 * 1_024,
            retentionDays: [.image: 3_650, .text: 3_650, .thumbnail: 3_650],
            maxCount: [
                .image: max(options.screenshots + 500, 2_000),
                .text: max(options.screenshots + 500, 2_000),
                .thumbnail: max(options.screenshots + 500, 2_000),
            ]
        )
        let history = try HistoryActor(cleanupPolicy: cleanup, baseURL: screenshotRoot)

        let generationStart = now()
        let image = try makeImage()
        for index in 0..<options.screenshots {
            _ = try await history.saveCapture(
                image: image,
                textContent: "bench-\(index)",
                ocrConfidence: 0.9,
                captureMode: "area"
            )
        }
        let generationMs = elapsedMs(since: generationStart)

        let coldStart = now()
        let coldActor = try HistoryActor(cleanupPolicy: cleanup, baseURL: screenshotRoot)
        let coldPage = try await coldActor.page(offset: 0, limit: 200)
        let coldPageMs = elapsedMs(since: coldStart)

        let warmStart = now()
        _ = try await coldActor.page(offset: 0, limit: 200)
        let warmPageMs = elapsedMs(since: warmStart)

        let searchStart = now()
        _ = try await coldActor.searchPage(
            query: "bench-\(max(0, options.screenshots / 2))",
            offset: 0,
            limit: 20
        )
        let searchMs = elapsedMs(since: searchStart)

        let thumbnailStart = now()
        for entry in coldPage.prefix(100) {
            _ = try? await coldActor.thumbnailData(for: entry.id)
        }
        let thumbnailMs = elapsedMs(since: thumbnailStart)
        let rssMB = Double(residentBytes()) / 1_024 / 1_024

        return ScreenshotMetrics(
            generationMs: generationMs,
            coldPageMs: coldPageMs,
            warmPageMs: warmPageMs,
            searchMs: searchMs,
            thumbnailMs: thumbnailMs,
            rssMB: rssMB,
            pageCount: coldPage.count
        )
    }

    // MARK: - Recording benchmark

    private static func runRecordingBench(
        options: Options,
        benchRoot: URL,
        fileManager: FileManager
    ) async throws -> RecordingMetrics {
        let recordingsRoot = benchRoot.appendingPathComponent("recordings", isDirectory: true)
        try fileManager.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        let indexURL =
            recordingsRoot
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")
        for index in 0..<options.recordings {
            let sessionID = UUID()
            let sessionRoot =
                recordingsRoot
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            let ledger = try RecordingSessionLedger(
                sessionRoot: sessionRoot,
                indexURL: indexURL,
                sessionID: sessionID
            )
            try await ledger.register(
                RecordingSessionRecord(
                    id: sessionID,
                    kind: .audio,
                    layout: .mixed,
                    startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                    segments: []
                ))
            let relativeMedia = "material-0.caf"
            let mediaURL = sessionRoot.appendingPathComponent(relativeMedia)
            try Data([0x01, 0x02]).write(to: mediaURL)
            let segment = PublishedSegment(
                id: UUID(),
                index: 0,
                files: ["mixed": relativeMedia],
                startSample: 0,
                sampleCount: 48_000,
                trackMap: ["mixed": 0],
                missingRanges: [],
                state: .published,
                videoURL: nil,
                videoTrackIndex: nil,
                materialURL: mediaURL
            )
            try await ledger.adoptPublishedSegment(segment)
        }

        let metadataStore = RecordingLibraryStore(
            fileURL: benchRoot.appendingPathComponent("recording-metadata.json")
        )
        let library = RecordingLibraryService(
            roots: [LibraryRoot(kind: .audio, root: recordingsRoot)],
            metadataStore: metadataStore
        )
        let scanStart = now()
        let snapshot = await library.scan()
        let scanMs = elapsedMs(since: scanStart)

        return RecordingMetrics(scanMs: scanMs, groups: snapshot.groups.count)
    }

    // MARK: - Media merge throughput

    private static func runMediaBench(
        options: Options,
        benchRoot: URL,
        fileManager: FileManager
    ) async throws -> MediaMetrics {
        let mediaRoot = benchRoot.appendingPathComponent("media", isDirectory: true)
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        var mediaMs: Double = 0
        var mediaBytes: Int64 = 0
        var mediaDuration: Double = 0
        if options.mediaCount >= 2 {
            var plans: [ExportPlan] = []
            for index in 0..<options.mediaCount {
                let url = try writeSilentCAF(
                    at: mediaRoot.appendingPathComponent("media-\(index).caf")
                )
                plans.append(
                    try makePlan(
                        caf: url,
                        outputDirectory: mediaRoot,
                        stem: "plan-\(index)"
                    ))
            }
            let merged = try RecordingPlanMerger.merge(
                plans,
                sessionID: plans[0].sessionID,
                destination: ExportDestination(directory: mediaRoot, stem: "merged"),
                outputSpec: plans[0].outputSpec
            )
            let exportStart = now()
            let result = try await RecordingCompositionExporter().export(merged) { _ in }
            mediaMs = elapsedMs(since: exportStart)
            mediaBytes =
                (try? result.outputURL.resourceValues(forKeys: [.fileSizeKey]))
                .flatMap(\.fileSize).map(Int64.init) ?? 0
            mediaDuration = CMTimeGetSeconds(AVURLAsset(url: result.outputURL).duration)
        }

        return MediaMetrics(mergeMs: mediaMs, bytes: mediaBytes, duration: mediaDuration)
    }

    // MARK: - Report

    private static func evaluateBudgets(measurement: Measurement, options: Options) -> [String] {
        guard options.assertBudgets else {
            return []
        }
        let budgets = measurement.budgets
        let screenshots = measurement.screenshots
        var failures: [String] = []
        if screenshots.coldPageMs > budgets.coldPageMs {
            failures.append("coldPageMs \(screenshots.coldPageMs) > \(budgets.coldPageMs)")
        }
        if screenshots.warmPageMs > budgets.warmPageMs {
            failures.append("warmPageMs \(screenshots.warmPageMs) > \(budgets.warmPageMs)")
        }
        if screenshots.searchMs > budgets.searchMs {
            failures.append("searchMs \(screenshots.searchMs) > \(budgets.searchMs)")
        }
        if measurement.recordings.scanMs > budgets.scanMs {
            failures.append("scanMs \(measurement.recordings.scanMs) > \(budgets.scanMs)")
        }
        if screenshots.thumbnailMs > budgets.thumbnailMs {
            failures.append("thumbnailMs \(screenshots.thumbnailMs) > \(budgets.thumbnailMs)")
        }
        if options.mediaCount >= 2, measurement.media.mergeMs > budgets.mediaMs {
            failures.append("mediaMs \(measurement.media.mergeMs) > \(budgets.mediaMs)")
        }
        if screenshots.rssMB > budgets.rssMB {
            failures.append("rssMB \(screenshots.rssMB) > \(budgets.rssMB)")
        }
        return failures
    }

    private static func makeReport(
        benchRoot: URL,
        options: Options,
        measurement: Measurement,
        failures: [String]
    ) -> [String: Any] {
        let screenshots = measurement.screenshots
        let records = measurement.recordings
        let media = measurement.media
        let budgets = measurement.budgets
        let report: [String: Any] = [
            "ok": failures.isEmpty,
            "root": benchRoot.path,
            "screenshots": [
                "count": options.screenshots,
                "generationMs": screenshots.generationMs,
                "coldPageMs": screenshots.coldPageMs,
                "warmPageMs": screenshots.warmPageMs,
                "searchMs": screenshots.searchMs,
                "thumbnailMs": screenshots.thumbnailMs,
                "rssMB": screenshots.rssMB,
                "pageCount": screenshots.pageCount,
            ],
            "recordings": [
                "count": options.recordings,
                "scanMs": records.scanMs,
                "groups": records.groups,
            ],
            "media": [
                "segments": options.mediaCount,
                "mergeMs": media.mergeMs,
                "bytes": media.bytes,
                "duration": media.duration,
            ],
            "budgets": [
                "coldPageMs": budgets.coldPageMs,
                "warmPageMs": budgets.warmPageMs,
                "searchMs": budgets.searchMs,
                "scanMs": budgets.scanMs,
                "thumbnailMs": budgets.thumbnailMs,
                "mediaMs": budgets.mediaMs,
                "rssMB": budgets.rssMB,
            ],
            "failures": failures,
        ]
        return report
    }

    // MARK: - Fixtures

    private static func makeImage() throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: 64,
                height: 40,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw BenchError.fixture("image context")
        }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        guard let image = context.makeImage() else {
            throw BenchError.fixture("image")
        }
        return image
    }

    private static func writeSilentCAF(at url: URL) throws -> URL {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 2
            )
        else {
            throw BenchError.fixture("audio format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 48_000
            )
        else {
            throw BenchError.fixture("audio buffer")
        }
        buffer.frameLength = 48_000
        try file.write(from: buffer)
        return url
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
            destination: ExportDestination(directory: outputDirectory, stem: stem)
        )
        return try RecordingExportPlanner.plan(
            session: session,
            selection: selection,
            audioSourcesBySegment: [segmentID: .recoveredMedia([caf])]
        )
    }

    // MARK: - Measurement

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func elapsedMs(since start: UInt64) -> Double {
        Double(now() - start) / 1_000_000
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { pointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    pointer,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private enum BenchError: Error {
        case fixture(String)
    }
}
