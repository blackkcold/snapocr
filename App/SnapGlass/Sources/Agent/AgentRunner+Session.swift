import AVFoundation
import CaptureCore
import Foundation
import SharedKit

/// Audio-session setup, readiness and stall waits, and artifact collection.
///
/// Kept in its own file so `AgentRunner` stays within the project's file and type
/// length budgets; every method here is driven by the scenario's ordered run.
extension AgentRunner {
    /// Creates the isolated controller and starts the real recording session.
    ///
    /// - Parameter scenario: The validated scenario to start.
    /// - Returns: The controller that owns the session, or `nil` on setup failure.
    func startSession(scenario: AgentScenario) async -> RecordingSessionController? {
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
    func makeController(defaults: UserDefaults) -> RecordingSessionController {
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

    func waitForReadiness(
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

    func injectMainThreadStallIfNeeded(scenario: AgentScenario) async {
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

    func waitForAudioDuration(scenario: AgentScenario) async {
        let anchor = readinessAt ?? origin
        let target = anchor.advanced(by: .seconds(scenario.audioSeconds))
        let remaining = clock.now.duration(to: target)
        guard remaining > .zero else { return }
        try? await Task.sleep(for: remaining)
    }

    func markReadiness() {
        guard readinessAt == nil else { return }
        readinessAt = clock.now
        AgentHUDMetrics.markRecordingPhaseStart()
        record("recording")
        logger.notice("agent session reached recording")
    }

    /// Collects published files from the real ledger, falling back to the panel's URL.
    func collectArtifacts(roots: RecordingPipelineRoots) async -> [AgentReport.Artifact] {
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
        for url in urls {
            let size = Self.fileSize(url)
            let duration = await mediaDuration(of: url)
            artifacts.append(AgentReport.Artifact(path: url.path, bytes: size, duration: duration))
        }
        return artifacts
    }

    /// Returns a playable duration, or `nil` when AVFoundation cannot decode the file.
    func mediaDuration(of url: URL) async -> Double? {
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

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
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
}
