import AppKit
import AVFoundation
import CaptureCore
import Foundation
import OSLog
import Security
import SharedKit

/// Entry point for the agent channel, called from the app delegate.
@MainActor
enum AgentRuntime {
    private static var runner: AgentRunner?

    /// Writes `agent.pid`, then runs the configured scenario.
    static func start() {
        guard let configuration = AgentMode.configuration else {
            let message: String
            if case let .invalid(reason) = AgentMode.activation {
                message = reason
            } else {
                message = "agent mode was activated without arguments"
            }
            failImmediately(message)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        do {
            try prepare(configuration)
        } catch {
            failImmediately("cannot prepare agent output: \(error)")
            return
        }

        let runner = AgentRunner(configuration: configuration)
        self.runner = runner
        runner.start()
    }

    private static func prepare(_ configuration: AgentMode.Configuration) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: configuration.rootURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: configuration.outputURL,
            withIntermediateDirectories: true
        )
        // Any code that still asks where recordings live resolves this root.
        setenv(AgentIsolation.rootEnvironmentKey, configuration.rootURL.path, 1)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try pid.write(
            to: configuration.outputURL.appendingPathComponent("agent.pid"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Reports an unusable agent launch without touching the user's library.
    private static func failImmediately(_ message: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapGlassAgent-failed-\(ProcessInfo.processInfo.processIdentifier)")
        let report = AgentReport(
            ok: false,
            scenario: "<launch>",
            app: AgentReport.AppFacts(
                pid: ProcessInfo.processInfo.processIdentifier,
                bundleID: Bundle.main.bundleIdentifier ?? "unknown",
                signedIdentity: "unknown",
                executablePath: Bundle.main.executableURL?.path ?? "unknown"
            ),
            session: AgentReport.SessionFacts(id: nil, kind: "none", published: false, audioMode: nil),
            artifacts: [],
            hud: AgentReport.HUDFacts(
                firstVisibleMs: nil,
                sizeThatFitsBeforeFirstVisible: 0,
                sizeThatFitsCount: 0,
                resizeCount: 0,
                applyCount: 0
            ),
            mainThread: AgentReport.MainThreadFacts(maxStallMs: 0, probeSamples: 0),
            supervisor: AgentReport.SupervisorFacts(
                settledAtMs: nil,
                settlementDuringStall: false,
                reason: nil,
                stopCalls: 0,
                mediaStarted: false
            ),
            readiness: AgentReport.ReadinessFacts(firstRealSampleAfterMs: nil, becameRecording: false),
            timeline: [],
            errors: [message]
        )
        try? report.write(to: directory)
        FileHandle.standardError.write(Data("agent launch failed: \(message)\nreport: \(directory.path)\n".utf8))
        exit(2)
    }
}

/// Warms the AppKit/SwiftUI window path before the measured scenario starts.
///
/// An agent launch has no SwiftUI scene, while a normal launch initializes the
/// menu bar label first. Without a warmup the first HUD creation would include
/// one-time framework loading that real users never pay at record time, and
/// `hud.firstVisibleMs` would measure that instead of presentation.
@MainActor
enum AgentHUDWarmup {
    /// Creates the real panel off-screen and dismisses it before the clock starts.
    static func run() async {
        AgentHUDMetrics.end()
        let actions = RecordingControlPanelActions(
            onCancel: {},
            onStop: {},
            onRetry: {},
            onReveal: { _ in },
            onDismiss: {},
            onHideWhileSaving: {},
            onCornerChange: { _ in },
            onToggleAudioDetails: {},
            onPreview: {},
            onStopPreview: {},
            onOpenLatest: { _ in },
            onOpenRecordings: {},
            onJoinExport: {}
        )
        let panel = RecordingControlPanel(
            on: nil,
            corner: .bottomLeading,
            opacity: 1,
            hoverRestore: false,
            actions: actions
        )
        panel.present(state: .starting(kind: .audio, phase: .startingAudioPipeline))
        panel.dismiss()
        // Let the panel's deferred measurement task drain while counting is off,
        // so warmup work cannot appear in the measured window.
        await Task.yield()
        await Task.yield()
        AgentHUDMetrics.end()
    }
}

/// Runs one scenario through the real recording controller, HUD, and export path.
@MainActor
final class AgentRunner {
    private let configuration: AgentMode.Configuration
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "com.snapglass", category: "agent")
    private let probe = AgentMainThreadProbe()

    private var origin: ContinuousClock.Instant = .now
    private var scenario: AgentScenario?
    private var controller: RecordingSessionController?
    private var roots: RecordingPipelineRoots?
    private var readinessAt: ContinuousClock.Instant?
    private var stallStartedAt: ContinuousClock.Instant?
    private var stallEndedAt: ContinuousClock.Instant?
    private var effectiveAudioMode = "system"
    private var timeline: [AgentReport.TimelineEntry] = []
    private var errors: [String] = []
    private var didFinish = false
    /// The last user-facing message the controller presented, for screen failures.
    private var lastPresentedMessage: String?

    init(configuration: AgentMode.Configuration) {
        self.configuration = configuration
    }

    /// Starts the scenario as a main-actor task.
    func start() {
        Task { await run() }
    }

    private func run() async {
        origin = clock.now
        probe.start()
        record("launch")
        logger.notice("agent scenario starting")

        let scenario: AgentScenario
        do {
            scenario = try AgentScenario.load(from: configuration.scenarioURL)
        } catch {
            errors.append("scenario: \(error)")
            await finish(sessionResult: nil, artifacts: [])
            return
        }
        self.scenario = scenario
        record("scenarioLoaded")
        if scenario.hudWarmup {
            await AgentHUDWarmup.run()
            record("hudWarmup")
        }

        if scenario.mode == AgentScenarioMode.recover.rawValue {
            await runRecovery(scenario: scenario)
            return
        }
        if scenario.mode == AgentScenarioMode.screen.rawValue {
            await runScreen(scenario: scenario)
            return
        }

        guard let controller = await startSession(scenario: scenario),
              let roots = self.roots else {
            await finish(sessionResult: nil, artifacts: [])
            return
        }

        // A stall that is not tied to readiness must start before the readiness
        // wait: the point is to block the main thread while the deadline fires.
        if scenario.simulateMainStallMs > 0, !scenario.simulateStallAfterStart {
            await injectMainThreadStallIfNeeded(scenario: scenario)
        }
        await waitForReadiness(scenario: scenario, controller: controller)
        if scenario.simulateMainStallMs > 0, scenario.simulateStallAfterStart {
            await injectMainThreadStallIfNeeded(scenario: scenario)
        }
        await waitForAudioDuration(scenario: scenario)
        AgentHUDMetrics.markRecordingPhaseEnd()
        record("stopRequested")
        let result = await controller.stopAudio()
        record("stopped")

        let artifacts = await collectArtifacts(roots: roots)
        await finish(sessionResult: result, artifacts: artifacts)
    }

    // MARK: Screen mode

    /// Runs a real screen recording for `screenSeconds`, then stops it.
    ///
    /// The path is the production one: the controller builds the session snapshot,
    /// checks the destination, passes the screen-permission gate, starts the real
    /// ScreenCaptureKit stream, and seals through the same ledger. Only the source
    /// selection and the three-second countdown are supplied by the harness.
    private func runScreen(scenario: AgentScenario) async {
        guard let agentDefaults = AgentPreferences(
            storage: AgentMode.preferenceOverrides(for: configuration)
        ) else {
            errors.append("preferences: cannot create the isolated in-memory store")
            await finish(sessionResult: nil, artifacts: [], screen: nil)
            return
        }
        let recordingRoot = configuration.rootURL
        let roots = RecordingPipelineRoots(
            sessionRoot: recordingRoot,
            indexURL: recordingRoot
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent("recording-index.json"),
            outputDirectory: recordingRoot
        )
        self.roots = roots

        let controller = makeController(defaults: agentDefaults)
        self.controller = controller
        // The screen snapshot resolves its destination from preferences, so the
        // isolated root must be the selected folder. Without this the run would
        // write into the user's real library.
        RecordingDestinationPreferences.setCustomDirectory(
            configuration.rootURL,
            for: .screen,
            in: agentDefaults
        )
        controller.screenPermissionGate = scenario.simulateScreenPermissionDenied
            ? .denied
            : .system
        controller.screenAudioModeOverride =
            AgentScenarioAudioMode(rawValue: scenario.audioMode)?.screenMode
        controller.screenAudioFailureInjection = scenario.simulateScreenAudioFailure
        // The report must state the mode this run actually asked for, not a default.
        effectiveAudioMode = scenario.audioMode
        controller.onStatusChange = { [weak self] status in
            guard let self, status == .recording else { return }
            self.markReadiness()
        }
        controller.onMessage = { [weak self] message, _ in
            guard let self else { return }
            self.lastPresentedMessage = message
        }

        AgentHUDMetrics.begin(origin: clock.now, timelineOrigin: origin)
        record("startRequested")
        guard let request = controller.beginScreenRequest() else {
            errors.append("startScreen: cannot reserve a screen request")
            await finish(sessionResult: nil, artifacts: [], screen: nil)
            return
        }

        let selection: RecordingSourceSelection
        switch await ScreenSourceProbe.load() {
        case let .ready(content):
            guard let display = content.displays.first else {
                errors.append("startScreen: no display is available to record")
                await finish(sessionResult: nil, artifacts: [], screen: nil)
                return
            }
            selection = RecordingSourceSelection(
                source: .display(displayID: display.displayID),
                displayID: display.displayID,
                displayFrame: display.frame,
                sourceFrame: display.frame,
                displayPixelSize: CGSize(width: display.width, height: display.height)
            )
        case .denied:
            errors.append("startScreen: screen capture access was denied during enumeration")
            await finish(sessionResult: nil, artifacts: [], screen: nil)
            return
        case .timedOut:
            errors.append("startScreen: source enumeration timed out")
            await finish(sessionResult: nil, artifacts: [], screen: nil)
            return
        case let .failed(message):
            errors.append("startScreen: \(message)")
            await finish(sessionResult: nil, artifacts: [], screen: nil)
            return
        }
        record("sourceSelected")

        await controller.startScreen(selection: selection, request: request)
        record("startReturned")

        await waitForScreenReadiness(scenario: scenario, controller: controller)
        if scenario.simulateMainStallMs > 0, scenario.simulateStallAfterStart {
            await injectMainThreadStallIfNeeded(scenario: scenario)
        }
        await waitForScreenDuration(scenario: scenario)
        AgentHUDMetrics.markRecordingPhaseEnd()
        record("stopRequested")
        _ = await controller.stopAndSave()
        record("stopped")
        await waitForScreenSettlement(controller: controller)
        record("settled")

        let screen = await collectScreenFacts(
            controller: controller,
            roots: roots
        )
        let artifacts = await collectScreenArtifacts(roots: roots)
        await finish(sessionResult: nil, artifacts: artifacts, screen: screen)
    }

    /// Waits for the writer's first accepted frame (the session's `.recording` state).
    private func waitForScreenReadiness(
        scenario: AgentScenario,
        controller: RecordingSessionController
    ) async {
        let deadline = clock.now.advanced(by: .seconds(scenario.firstSampleDeadlineSeconds))
        while readinessAt == nil, clock.now < deadline {
            if controller.status == .recording {
                markReadiness()
                break
            }
            if controller.status == .idle { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if readinessAt == nil, scenario.expect.becameRecording != false {
            errors.append("readiness: no accepted screen frame before deadline")
        }
    }

    private func waitForScreenDuration(scenario: AgentScenario) async {
        let anchor = readinessAt ?? origin
        let target = anchor.advanced(by: .seconds(scenario.screenSeconds))
        let remaining = clock.now.duration(to: target)
        guard remaining > .zero else { return }
        try? await Task.sleep(for: remaining)
    }

    /// Waits for the real stop to finish after the bounded UI wait returned.
    ///
    /// The app must not terminate while `finishWriting` is still running: that is
    /// exactly how a chunk is left at zero bytes. The bounded wait is generous and
    /// only exists so a truly stuck stop still produces a report.
    private func waitForScreenSettlement(controller: RecordingSessionController) async {
        let deadline = clock.now.advanced(by: .seconds(60))
        while controller.status != .idle && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if controller.status != .idle {
            errors.append("screen: the stop did not settle within 60s")
        }
    }

    /// Reads the writer diagnostics and the on-disk chunk facts for the report.
    private func collectScreenFacts(
        controller: RecordingSessionController,
        roots: RecordingPipelineRoots
    ) async -> AgentReport.ScreenFacts {
        let diagnostics = await controller.screenWriterDiagnostics()
        let chunks = AgentScreenMedia.chunkFacts(root: configuration.rootURL)
        let published = await AgentScreenMedia.publishedVideoURLs(roots: roots)
        let publishedURL = published?.last
        var duration: Double?
        if let publishedURL {
            duration = await mediaDuration(of: publishedURL)
        } else if let largest = chunks.largestURL {
            duration = await mediaDuration(of: largest)
        }
        let audioURL = publishedURL ?? chunks.largestURL
        var hasAudio = false
        if let audioURL {
            hasAudio = await hasAudioTrack(audioURL)
        }
        return AgentReport.ScreenFacts(
            writerStart: diagnostics?.writerStart ?? false,
            syncDropCount: diagnostics?.syncDropCount ?? 0,
            nonSyncDropCount: diagnostics?.nonSyncDropCount ?? 0,
            appendFailureCount: diagnostics?.appendFailureCount ?? 0,
            lastError: diagnostics?.lastErrorDescription,
            published: !(published?.isEmpty ?? true),
            becameWaitingForFrame: controller.didAwaitFirstVideoFrame,
            chunkCount: chunks.count,
            zeroByteChunkCount: chunks.zeroByteCount,
            chunkBytes: chunks.largestBytes,
            failureMessage: lastPresentedMessage,
            artifactDuration: duration,
            audioTrackPresent: hasAudio,
            audioStartFailed: diagnostics?.audioFailureReason != nil,
            audioFailureReason: diagnostics?.audioFailureReason
        )
    }

    /// Whether a media file carries an audio track AVFoundation can see.
    private func hasAudioTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return !tracks.isEmpty
    }

    /// Collects the published screen videos and the raw chunks as artifacts.
    private func collectScreenArtifacts(roots: RecordingPipelineRoots) async -> [AgentReport.Artifact] {
        var urls: [URL] = []
        if let published = await AgentScreenMedia.publishedVideoURLs(roots: roots) {
            urls.append(contentsOf: published)
        }
        urls.append(contentsOf: AgentScreenMedia.chunkFacts(root: configuration.rootURL).urls)
        var unique: [URL] = []
        for url in urls where !unique.contains(url) { unique.append(url) }
        var artifacts: [AgentReport.Artifact] = []
        for url in unique {
            let size = Self.fileSize(url)
            let duration = await mediaDuration(of: url)
            artifacts.append(AgentReport.Artifact(path: url.path, bytes: size, duration: duration))
        }
        return artifacts
    }

    // MARK: Recovery mode

    /// Scans an isolated root, adopts the interrupted session, and exports it.
    ///
    /// The run proves the real path end to end: catalog → adoption → the same
    /// `publishedSessions` list the window reads → the real export service. It
    /// never writes outside `--agent-root` and never copies media.
    private func runRecovery(scenario: AgentScenario) async {
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
        var recovery = AgentReport.RecoveryFacts(
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
            return
        }
        recovery.catalogDuration = target.duration

        record("recoveryAdopt")
        do {
            _ = try await service.recover(target)
            recovery.adopted += 1
            let afterFirst = try await RecordingSessionLedger.publishedSessions(
                in: recordingRoot, indexURL: indexURL
            )
            // Idempotency: a second recovery of the same session must not add a
            // second entry, and must not append a second journal line.
            let journalBefore = try? Data(
                contentsOf: Self.journalURL(root: recordingRoot, sessionID: target.id)
            )
            _ = try await service.recover(target)
            let afterSecond = try await RecordingSessionLedger.publishedSessions(
                in: recordingRoot, indexURL: indexURL
            )
            let journalAfter = try? Data(
                contentsOf: Self.journalURL(root: recordingRoot, sessionID: target.id)
            )
            recovery.publishedAfterRecovery = afterSecond.count
            recovery.idempotent = afterSecond.count == 1
                && afterFirst.count == afterSecond.count
                && journalBefore == journalAfter
        } catch {
            errors.append("recovery adopt: \(String(reflecting: error))")
            await finish(sessionResult: nil, artifacts: [], recovery: recovery)
            return
        }
        record("recoveryAdopted")

        var artifacts: [AgentReport.Artifact] = []
        do {
            let export = try await exportRecoveredSession(target, roots: exportRoots)
            recovery.exportedPath = export.path
            recovery.exportedDuration = export.duration
            artifacts = [export]
        } catch {
            errors.append("recovery export: \(String(reflecting: error))")
        }
        record("recoveryExported")

        await finish(sessionResult: nil, artifacts: artifacts, recovery: recovery)
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

    private static func journalURL(root: URL, sessionID: UUID) -> URL {
        root.appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("journal.ndjson")
    }

    /// Counts durable checkpoint lines in a session journal.
    private static func journalFacts(root: URL, sessionID: UUID) -> AgentReport.JournalFacts? {
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

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Failures specific to the recovery harness itself.
    private enum RecoveryHarnessError: Error {
        case sessionNotListed
        case exportUnavailable(String)
    }

    /// Creates the isolated controller and starts the real recording session.
    ///
    /// - Parameter scenario: The validated scenario to start.
    /// - Returns: The controller that owns the session, or `nil` on setup failure.
    private func startSession(scenario: AgentScenario) async -> RecordingSessionController? {
        guard let agentDefaults = AgentPreferences(
            storage: AgentMode.preferenceOverrides(for: configuration)
        ) else {
            errors.append("preferences: cannot create the isolated in-memory store")
            return nil
        }
        let recordingRoot = configuration.rootURL
        let roots = RecordingPipelineRoots(
            sessionRoot: recordingRoot,
            indexURL: recordingRoot
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent("recording-index.json"),
            outputDirectory: recordingRoot
        )
        self.roots = roots

        let controller = makeController(defaults: agentDefaults)
        self.controller = controller
        if let deadline = configuration.deadlineSeconds {
            controller.firstSampleDeadlineOverride = .seconds(deadline)
        }
        controller.suppressFirstSampleReadiness = scenario.suppressFirstSample
        controller.onStatusChange = { [weak self] status in
            guard let self, status == .recording else { return }
            self.markReadiness()
        }

        let audioConfiguration = makeAudioConfiguration(for: scenario)
        effectiveAudioMode = audioConfiguration.mode.agentName
        AgentHUDMetrics.begin(origin: clock.now, timelineOrigin: origin)
        record("startRequested")
        guard let request = controller.beginAudioRequest(requiresMicrophonePermission: false) else {
            errors.append("startAudio: cannot reserve an audio request")
            return nil
        }
        do {
            try await controller.startAudio(
                audioConfiguration,
                roots: roots,
                isCustomDestination: false,
                request: request
            )
        } catch {
            let description = String(reflecting: error)
            errors.append("startAudio: \(description)")
            if Self.indicatesUnavailableDisplay(description) {
                errors.append(
                    "display asleep / no display available: system audio capture cannot start; "
                        + "no microphone fallback was attempted"
                )
            }
        }
        return controller
    }

    /// Builds the production controller with the same pipeline factory the app uses.
    private func makeController(defaults: UserDefaults) -> RecordingSessionController {
        let backlog = RecordingBacklogPolicy(
            highWatermarkBytes: 512 * 1_024 * 1_024,
            lowWatermarkBytes: 128 * 1_024 * 1_024
        )
        return RecordingSessionController(
            captureOrchestrator: CaptureOrchestrator(),
            defaults: defaults,
            audioPipelineFactory: { configuration, roots, expectedVolumeUUID in
                try await RecordingPipelineSetupQueue.run {
                    try RecordingAudioPipelineFactory.makeSpaceGated(
                        configuration: configuration,
                        roots: roots,
                        expectedVolumeUUID: expectedVolumeUUID,
                        backlog: backlog
                    )
                }
            }
        )
    }

    private func makeAudioConfiguration(for scenario: AgentScenario) -> AudioRecordingConfiguration {
        let mode = AgentScenarioAudioMode(rawValue: scenario.audioMode) ?? .system
        let channelCounts: [RecordingTrackRole: Int]
        let sourceMode: AudioSourceMode
        switch mode {
        case .system:
            sourceMode = .system
            channelCounts = [.mixed: 2]
        case .microphone:
            sourceMode = .microphone
            channelCounts = [.mixed: 1]
        case .systemAndMicrophone:
            sourceMode = .systemAndMicrophone
            channelCounts = [.mixed: 2]
        case .none:
            // Audio-only scenarios require a real source; `none` is screen-only.
            sourceMode = .system
            channelCounts = [.mixed: 2]
        }
        return AudioRecordingConfiguration(
            kind: .audio,
            mode: sourceMode,
            layout: .mixed,
            sampleRate: 48_000,
            channelCountByRole: channelCounts,
            bitRate: 128_000
        )
    }

    private func waitForReadiness(
        scenario: AgentScenario,
        controller: RecordingSessionController
    ) async {
        let deadline = clock.now.advanced(by: .seconds(scenario.firstSampleDeadlineSeconds))
        while readinessAt == nil, clock.now < deadline {
            if controller.audioStateMachine.state == .recording {
                markReadiness()
                break
            }
            if controller.lastAudioResult?.failure != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if readinessAt == nil, scenario.expect.becameRecording != false {
            errors.append("readiness: no real audio sample before deadline")
        }
    }

    private func injectMainThreadStallIfNeeded(scenario: AgentScenario) async {
        guard scenario.simulateMainStallMs > 0 else { return }
        guard scenario.simulateStallAfterStart == false || readinessAt != nil else {
            errors.append("stall: not injected because readiness was never reached")
            return
        }
        record("stallStart")
        stallStartedAt = clock.now
        blockMainThread(seconds: Double(scenario.simulateMainStallMs) / 1_000)
        stallEndedAt = clock.now
        record("stallEnd")
    }

    /// Deliberately blocks the main thread for the configured failure injection.
    ///
    /// Kept synchronous so the async context cannot move the block off the main
    /// thread; the independent probe is what measures the resulting stall.
    private func blockMainThread(seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func waitForAudioDuration(scenario: AgentScenario) async {
        let anchor = readinessAt ?? origin
        let target = anchor.advanced(by: .seconds(scenario.audioSeconds))
        let remaining = clock.now.duration(to: target)
        guard remaining > .zero else { return }
        try? await Task.sleep(for: remaining)
    }

    private func markReadiness() {
        guard readinessAt == nil else { return }
        readinessAt = clock.now
        AgentHUDMetrics.markRecordingPhaseStart()
        record("recording")
        logger.notice("agent session reached recording")
    }

    /// Collects published files from the real ledger, falling back to the panel's URL.
    private func collectArtifacts(roots: RecordingPipelineRoots) async -> [AgentReport.Artifact] {
        var urls: [URL] = []
        if let pipeline = controller?.audioPipeline,
           let record = try? await pipeline.ledger.snapshot() {
            for segment in record.segments where segment.state == .published {
                for relative in segment.files.values.sorted() {
                    let url = roots.outputDirectory.appendingPathComponent(relative)
                    if !urls.contains(url) { urls.append(url) }
                }
            }
        }
        if urls.isEmpty, let url = controller?.latestAudioOutputURL {
            urls.append(url)
        }

        var artifacts: [AgentReport.Artifact] = []
        let fileManager = FileManager.default
        for url in urls {
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let duration = await mediaDuration(of: url)
            artifacts.append(AgentReport.Artifact(path: url.path, bytes: size, duration: duration))
        }
        return artifacts
    }

    /// Returns a playable duration, or `nil` when AVFoundation cannot decode the file.
    private func mediaDuration(of url: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else { return nil }
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    private func finish(
        sessionResult: AudioRecordingResult?,
        artifacts: [AgentReport.Artifact],
        screen: AgentReport.ScreenFacts? = nil,
        recovery: AgentReport.RecoveryFacts? = nil,
        journal: AgentReport.JournalFacts? = nil
    ) async {
        guard !didFinish else { return }
        didFinish = true
        record("reportBuild")

        let probeResult = probe.stop()
        AgentHUDMetrics.end()
        let hud = AgentReport.HUDFacts(
            firstVisibleMs: AgentHUDMetrics.firstVisibleMs,
            sizeThatFitsBeforeFirstVisible: AgentHUDMetrics.sizeThatFitsBeforeFirstVisible,
            sizeThatFitsCount: AgentHUDMetrics.sizeThatFitsCount,
            resizeCount: AgentHUDMetrics.resizeCount,
            applyCount: AgentHUDMetrics.applyCount,
            resizeCountRecordingPhase: AgentHUDMetrics.resizeCountRecordingPhase,
            resizes: AgentHUDMetrics.resizeRecords,
            corner: configuration.hudCorner,
            warmedUp: scenario?.hudWarmup ?? false
        )
        let readiness = AgentReport.ReadinessFacts(
            firstRealSampleAfterMs: readinessAt.map { AgentHUDMetrics.milliseconds(from: origin, to: $0) },
            becameRecording: readinessAt != nil
        )
        let supervisorDiagnostics = await controller?.settlementDiagnostics()
        let settledAtMs = supervisorDiagnostics?.settledAt.map {
            AgentHUDMetrics.milliseconds(from: origin, to: $0)
        }
        let settlementDuringStall: Bool
        if let settled = supervisorDiagnostics?.settledAt,
           let stallStartedAt,
           let stallEndedAt {
            settlementDuringStall =
                settled >= stallStartedAt && settled <= stallEndedAt
                && supervisorDiagnostics?.reason == .deadline
        } else {
            settlementDuringStall = false
        }
        let supervisor = AgentReport.SupervisorFacts(
            settledAtMs: settledAtMs,
            settlementDuringStall: settlementDuringStall,
            reason: supervisorDiagnostics?.reason?.rawValue,
            stopCalls: supervisorDiagnostics?.stopCalls ?? 0,
            mediaStarted: supervisorDiagnostics?.mediaStarted ?? false
        )
        var timeline = self.timeline
        if let applied = AgentHUDMetrics.firstApplyTimelineMs {
            timeline.append(AgentReport.TimelineEntry(t: applied, event: "hudApply"))
        }
        if let visible = AgentHUDMetrics.firstVisibleTimelineMs {
            timeline.append(AgentReport.TimelineEntry(t: visible, event: "hudVisible"))
        }
        if let settledAtMs {
            timeline.append(AgentReport.TimelineEntry(t: settledAtMs, event: "supervisorSettled"))
        }
        for resize in hud.resizes {
            timeline.append(AgentReport.TimelineEntry(t: resize.t, event: "resize"))
        }
        timeline.sort { $0.t < $1.t }

        let report = AgentReport(
            ok: false,
            scenario: scenario?.name ?? "<unknown>",
            app: AgentReport.AppFacts(
                pid: ProcessInfo.processInfo.processIdentifier,
                bundleID: Bundle.main.bundleIdentifier ?? "unknown",
                signedIdentity: Self.signingIdentity(),
                executablePath: Bundle.main.executableURL?.path ?? "unknown"
            ),
            session: AgentReport.SessionFacts(
                id: sessionResult?.sessionID.uuidString.lowercased(),
                kind: sessionResult.map { $0.kind == .audio ? "audio" : "screen" }
                    ?? (scenario?.mode == AgentScenarioMode.screen.rawValue ? "screen" : "audio"),
                published: sessionResult.map { $0.segmentCount > 0 && $0.failure == nil }
                    ?? (screen?.published ?? false),
                audioMode: effectiveAudioMode
            ),
            artifacts: artifacts,
            hud: hud,
            mainThread: AgentReport.MainThreadFacts(
                maxStallMs: probeResult.maxStallMs,
                probeSamples: probeResult.sampleCount
            ),
            supervisor: supervisor,
            readiness: readiness,
            screen: screen,
            recovery: recovery,
            journal: journal ?? sessionResult.flatMap {
                Self.journalFacts(root: configuration.rootURL, sessionID: $0.sessionID)
            },
            timeline: timeline,
            errors: errors
        )

        let evaluated = evaluate(report)
        do {
            try evaluated.write(to: configuration.outputURL)
        } catch {
            FileHandle.standardError.write(Data("cannot write report: \(error)\n".utf8))
        }
        logger.notice("agent scenario finished ok=\(evaluated.ok, privacy: .public)")

        // The report is on disk before termination; the launch wrapper owns exit mapping.
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            exit(evaluated.ok ? 0 : 3)
        }
    }

    /// Applies scenario expectations and returns the final report.
    private func evaluate(_ report: AgentReport) -> AgentReport {
        var report = report
        var failures = report.errors
        let expect = scenario?.expect ?? AgentScenario.Expect()

        let playable = report.artifacts.contains { ($0.duration ?? 0) > 0 }
        if expect.artifactPlayable, !playable {
            failures.append("expectation: no playable artifact")
        }
        if let limit = expect.hudFirstVisibleUnderMs {
            if let visible = report.hud.firstVisibleMs {
                if visible >= limit {
                    failures.append("expectation: hud first visible \(visible)ms >= \(limit)ms")
                }
            } else {
                failures.append("expectation: hud never became visible")
            }
        }
        if let expected = expect.sizeThatFitsBeforeFirstVisible,
           report.hud.sizeThatFitsBeforeFirstVisible != expected {
            failures.append(
                "expectation: sizeThatFitsBeforeFirstVisible "
                    + "\(report.hud.sizeThatFitsBeforeFirstVisible) != \(expected)"
            )
        }
        if let expected = expect.becameRecording, report.readiness.becameRecording != expected {
            failures.append("expectation: becameRecording != \(expected)")
        }
        if let minimum = expect.mainThreadMaxStallAtLeastMs,
           report.mainThread.maxStallMs < minimum {
            failures.append(
                "expectation: maxStallMs \(report.mainThread.maxStallMs) < \(minimum)"
            )
        }
        if let maximum = expect.maxResizeCount, report.hud.resizeCount > maximum {
            failures.append("expectation: resizeCount \(report.hud.resizeCount) > \(maximum)")
        }
        if let maximum = expect.maxRecordingResizeCount,
           report.hud.resizeCountRecordingPhase > maximum {
            failures.append(
                "expectation: resizeCountRecordingPhase "
                    + "\(report.hud.resizeCountRecordingPhase) > \(maximum)"
            )
        }
        if let expected = expect.settlementDuringStall,
           report.supervisor.settlementDuringStall != expected {
            failures.append(
                "expectation: settlementDuringStall \(report.supervisor.settlementDuringStall) != \(expected)"
            )
        }
        if let expected = expect.supervisorStopCalls,
           report.supervisor.stopCalls != expected {
            failures.append(
                "expectation: supervisorStopCalls \(report.supervisor.stopCalls) != \(expected)"
            )
        }
        if expect.noZeroByteArtifacts == true {
            let empty = report.artifacts.filter { $0.bytes == 0 }.count
            if empty > 0 {
                failures.append("expectation: \(empty) zero-byte artifact(s) published")
            }
        }
        if let minimum = expect.minCheckpointCount {
            let count = report.journal?.checkpointCount ?? 0
            if count < minimum {
                failures.append("expectation: checkpointCount \(count) < \(minimum)")
            }
        }
        if let recoveryExpect = scenario?.recoveryExpect {
            failures.append(contentsOf: Self.evaluateRecovery(recoveryExpect, report: report))
        }
        if let screenExpect = scenario?.screenExpect {
            if let screen = report.screen {
                failures.append(
                    contentsOf: AgentScreenExpectation.evaluate(
                        screenExpect,
                        screen: screen,
                        screenSeconds: scenario?.screenSeconds ?? 0
                    )
                )
            } else {
                failures.append("expectation: screen facts are missing")
            }
        }

        report.errors = failures
        report.ok = failures.isEmpty
        return report
    }

    /// Applies `recoveryExpect` assertions against the recovery facts.
    private static func evaluateRecovery(
        _ expect: AgentRecoveryExpect,
        report: AgentReport
    ) -> [String] {
        var failures: [String] = []
        let recovery = report.recovery
        if let minimum = expect.minRecoverable, (recovery?.scanned ?? 0) < minimum {
            failures.append("expectation: recoverable \(recovery?.scanned ?? 0) < \(minimum)")
        }
        if expect.expectExportPlayable == true {
            if let duration = recovery?.exportedDuration {
                if duration <= 0 {
                    failures.append("expectation: exported duration \(duration) is not playable")
                }
            } else {
                failures.append("expectation: no exported file")
            }
        }
        if expect.expectZeroByteHidden == true, recovery?.zeroByteVisible == true {
            failures.append("expectation: zero-byte session appeared as recoverable")
        }
        if expect.expectIdempotent == true, recovery?.idempotent != true {
            failures.append("expectation: recovery was not idempotent")
        }
        if let delta = expect.maxDurationDeltaSeconds {
            let catalog = recovery?.catalogDuration ?? 0
            let exported = recovery?.exportedDuration ?? 0
            if abs(catalog - exported) > delta {
                failures.append(
                    "expectation: exported duration \(exported)s differs from catalog "
                        + "\(catalog)s by more than \(delta)s"
                )
            }
        }
        return failures
    }

    /// Whether a start failure means the display/SCK source is unavailable.
    ///
    /// The harness never falls back to another source: a default-source scenario
    /// must fail explicitly when the system audio stream cannot start.
    private static func indicatesUnavailableDisplay(_ description: String) -> Bool {
        let lowered = description.lowercased()
        return lowered.contains("no display available")
            || lowered.contains("display asleep")
            || lowered.contains("display is asleep")
    }

    private func record(_ event: String) {
        timeline.append(
            AgentReport.TimelineEntry(
                t: AgentHUDMetrics.milliseconds(from: origin, to: .now),
                event: event
            )
        )
    }

    /// Reads the authority of the code signature that is currently running.
    private static func signingIdentity() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return "unknown" }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return "unknown" }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
              let commonName else { return "unknown" }
        return commonName as String
    }
}

private extension AudioSourceMode {
    var agentName: String {
        switch self {
        case .system: "system"
        case .microphone: "microphone"
        case .systemAndMicrophone: "systemAndMicrophone"
        case .none: "none"
        }
    }
}
