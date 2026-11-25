import AVFoundation
import CaptureCore
import CoreGraphics
import Foundation
import SharedKit

/// Screen-record scenario preparation, the production start/stop path, and the
/// screen facts the report needs.
///
/// Kept in its own file so `AgentRunner` stays within the project's file and type
/// length budgets.
extension AgentRunner {
    /// Runs a real screen recording for `screenSeconds`, then stops it.
    ///
    /// The path is the production one: the controller builds the session snapshot,
    /// checks the destination, passes the screen-permission gate, starts the real
    /// ScreenCaptureKit stream, and seals through the same ledger. Only the source
    /// selection and the three-second countdown are supplied by the harness.
    func runScreen(scenario: AgentScenario) async {
        guard let prepared = await prepareScreenRun(scenario: scenario) else { return }
        guard let selection = await selectScreenSource() else { return }
        record("sourceSelected")

        await prepared.controller.startScreen(selection: selection, request: prepared.request)
        record("startReturned")

        await waitForScreenReadiness(scenario: scenario, controller: prepared.controller)
        if scenario.simulateMainStallMs > 0, scenario.simulateStallAfterStart {
            await injectMainThreadStallIfNeeded(scenario: scenario)
        }
        await waitForScreenDuration(scenario: scenario)
        AgentHUDMetrics.markRecordingPhaseEnd()
        record("stopRequested")
        _ = await prepared.controller.stopAndSave()
        record("stopped")
        await waitForScreenSettlement(controller: prepared.controller)
        record("settled")

        let screen = await collectScreenFacts(
            controller: prepared.controller,
            roots: prepared.roots
        )
        let artifacts = await collectScreenArtifacts(roots: prepared.roots)
        await finish(sessionResult: nil, artifacts: artifacts, screen: screen)
    }

    /// Builds the isolated controller, wires the screen gates, and reserves the request.
    private func prepareScreenRun(scenario: AgentScenario) async -> ScreenRun? {
        guard
            let agentDefaults = AgentPreferences(
                storage: AgentMode.preferenceOverrides(for: configuration)
            )
        else {
            errors.append("preferences: cannot create the isolated in-memory store")
            await finish(sessionResult: nil, artifacts: [], screen: nil)
            return nil
        }
        let recordingRoot = configuration.rootURL
        let roots = RecordingPipelineRoots(
            sessionRoot: recordingRoot,
            indexURL:
                recordingRoot
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
        configureScreenController(controller, scenario: scenario)

        AgentHUDMetrics.begin(origin: clock.now, timelineOrigin: origin)
        record("startRequested")
        guard let request = controller.beginScreenRequest() else {
            errors.append("startScreen: cannot reserve a screen request")
            await finish(sessionResult: nil, artifacts: [], screen: nil)
            return nil
        }
        return ScreenRun(controller: controller, roots: roots, request: request)
    }

    /// Applies the scenario's permission, audio, and status configuration.
    private func configureScreenController(
        _ controller: RecordingSessionController,
        scenario: AgentScenario
    ) {
        controller.screenPermissionGate =
            scenario.simulateScreenPermissionDenied
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
    }

    /// Enumerates the screen sources and returns the display selection to record.
    private func selectScreenSource() async -> RecordingSourceSelection? {
        switch await ScreenSourceProbe.load() {
        case let .ready(content):
            guard let display = content.displays.first else {
                errors.append("startScreen: no display is available to record")
                await finish(sessionResult: nil, artifacts: [], screen: nil)
                return nil
            }
            return RecordingSourceSelection(
                source: .display(displayID: display.displayID),
                displayID: display.displayID,
                displayFrame: display.frame,
                sourceFrame: display.frame,
                displayPixelSize: CGSize(width: display.width, height: display.height)
            )
        case .denied:
            errors.append("startScreen: screen capture access was denied during enumeration")
        case .timedOut:
            errors.append("startScreen: source enumeration timed out")
        case let .failed(message):
            errors.append("startScreen: \(message)")
        }
        await finish(sessionResult: nil, artifacts: [], screen: nil)
        return nil
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
}

/// The prepared inputs for one screen run.
private struct ScreenRun {
    let controller: RecordingSessionController
    let roots: RecordingPipelineRoots
    let request: RecordingRequestIdentity
}
