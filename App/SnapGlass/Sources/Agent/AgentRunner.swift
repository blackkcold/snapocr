import AppKit
import CaptureCore
import Foundation
import OSLog

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
///
/// The scenario modes and the report pipeline live in extensions so this class
/// stays within the project's type-length budget:
/// `AgentRunner+Session`, `AgentRunner+Screen`, `AgentRunner+Recovery`, and
/// `AgentRunner+Report` own the phases that do not belong to the run itself.
///
/// The stored state is `internal` only because those extensions live in separate
/// files; nothing outside the app target can reach this class.
@MainActor
final class AgentRunner {
    let configuration: AgentMode.Configuration
    let clock = ContinuousClock()
    let logger = Logger(subsystem: "com.snapglass", category: "agent")
    let probe = AgentMainThreadProbe()

    var origin: ContinuousClock.Instant = .now
    var scenario: AgentScenario?
    var controller: RecordingSessionController?
    var roots: RecordingPipelineRoots?
    var readinessAt: ContinuousClock.Instant?
    var stallStartedAt: ContinuousClock.Instant?
    var stallEndedAt: ContinuousClock.Instant?
    var effectiveAudioMode = "system"
    var timeline: [AgentReport.TimelineEntry] = []
    var errors: [String] = []
    var didFinish = false
    /// The last user-facing message the controller presented, for screen failures.
    var lastPresentedMessage: String?

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
}
