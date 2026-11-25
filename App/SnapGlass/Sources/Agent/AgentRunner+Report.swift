import AppKit
import CaptureCore
import Foundation
import OSLog
import Security

/// Report construction, expectation evaluation, and termination.
///
/// Kept in its own file so `AgentRunner` stays within the project's file and type
/// length budgets.
extension AgentRunner {
    /// Builds the final report, applies the expectations, writes it, and terminates.
    func finish(
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
        let hud = makeHUDFacts()
        let readiness = AgentReport.ReadinessFacts(
            firstRealSampleAfterMs: readinessAt.map { AgentHUDMetrics.milliseconds(from: origin, to: $0) },
            becameRecording: readinessAt != nil
        )
        let supervisorDiagnostics = await controller?.settlementDiagnostics()
        let supervisor = makeSupervisorFacts(supervisorDiagnostics)
        let report = AgentReport(
            ok: false,
            scenario: scenario?.name ?? "<unknown>",
            app: Self.appFacts(),
            session: makeSessionFacts(sessionResult: sessionResult, screen: screen),
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
            journal: journal
                ?? sessionResult.flatMap {
                    Self.journalFacts(root: configuration.rootURL, sessionID: $0.sessionID)
                },
            timeline: makeTimeline(hud: hud, settledAtMs: supervisor.settledAtMs),
            errors: errors
        )

        complete(report)
    }

    /// Writes the evaluated report, then terminates the process.
    private func complete(_ report: AgentReport) {
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

    /// Snapshots the HUD counters for the report.
    private func makeHUDFacts() -> AgentReport.HUDFacts {
        AgentReport.HUDFacts(
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
    }

    /// Snapshots the settlement supervisor diagnostics for the report.
    private func makeSupervisorFacts(
        _ diagnostics: RecordingSettlementSupervisor.Diagnostics?
    ) -> AgentReport.SupervisorFacts {
        let settledAtMs = diagnostics?.settledAt.map {
            AgentHUDMetrics.milliseconds(from: origin, to: $0)
        }
        let settlementDuringStall: Bool
        if let settled = diagnostics?.settledAt,
            let stallStartedAt,
            let stallEndedAt
        {
            settlementDuringStall =
                settled >= stallStartedAt && settled <= stallEndedAt
                && diagnostics?.reason == .deadline
        } else {
            settlementDuringStall = false
        }
        return AgentReport.SupervisorFacts(
            settledAtMs: settledAtMs,
            settlementDuringStall: settlementDuringStall,
            reason: diagnostics?.reason?.rawValue,
            stopCalls: diagnostics?.stopCalls ?? 0,
            mediaStarted: diagnostics?.mediaStarted ?? false
        )
    }

    /// Merges the recorded events with the HUD and supervisor milestones.
    private func makeTimeline(
        hud: AgentReport.HUDFacts,
        settledAtMs: Int?
    ) -> [AgentReport.TimelineEntry] {
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
        return timeline
    }

    /// Describes the session the scenario actually started.
    private func makeSessionFacts(
        sessionResult: AudioRecordingResult?,
        screen: AgentReport.ScreenFacts?
    ) -> AgentReport.SessionFacts {
        AgentReport.SessionFacts(
            id: sessionResult?.sessionID.uuidString.lowercased(),
            kind: sessionResult.map { $0.kind == .audio ? "audio" : "screen" }
                ?? (scenario?.mode == AgentScenarioMode.screen.rawValue ? "screen" : "audio"),
            published: sessionResult.map { $0.segmentCount > 0 && $0.failure == nil }
                ?? (screen?.published ?? false),
            audioMode: effectiveAudioMode
        )
    }

    /// Applies scenario expectations and returns the final report.
    private func evaluate(_ report: AgentReport) -> AgentReport {
        var report = report
        let expect = scenario?.expect ?? AgentScenario.Expect()
        var failures = report.errors
        failures.append(contentsOf: Self.artifactExpectationFailures(expect, report: report))
        failures.append(contentsOf: Self.runtimeExpectationFailures(expect, report: report))
        failures.append(contentsOf: Self.journalExpectationFailures(expect, report: report))
        failures.append(contentsOf: modeExpectationFailures(report: report))
        report.errors = failures
        report.ok = failures.isEmpty
        return report
    }

    /// Checks the playable-artifact and HUD presentation expectations.
    private static func artifactExpectationFailures(
        _ expect: AgentScenario.Expect,
        report: AgentReport
    ) -> [String] {
        var failures: [String] = []
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
            report.hud.sizeThatFitsBeforeFirstVisible != expected
        {
            failures.append(
                "expectation: sizeThatFitsBeforeFirstVisible "
                    + "\(report.hud.sizeThatFitsBeforeFirstVisible) != \(expected)"
            )
        }
        return failures
    }

    /// Checks the readiness, main-thread, resize, and supervisor expectations.
    private static func runtimeExpectationFailures(
        _ expect: AgentScenario.Expect,
        report: AgentReport
    ) -> [String] {
        var failures: [String] = []
        if let expected = expect.becameRecording, report.readiness.becameRecording != expected {
            failures.append("expectation: becameRecording != \(expected)")
        }
        if let minimum = expect.mainThreadMaxStallAtLeastMs,
            report.mainThread.maxStallMs < minimum
        {
            failures.append(
                "expectation: maxStallMs \(report.mainThread.maxStallMs) < \(minimum)"
            )
        }
        if let maximum = expect.maxResizeCount, report.hud.resizeCount > maximum {
            failures.append("expectation: resizeCount \(report.hud.resizeCount) > \(maximum)")
        }
        if let maximum = expect.maxRecordingResizeCount,
            report.hud.resizeCountRecordingPhase > maximum
        {
            failures.append(
                "expectation: resizeCountRecordingPhase "
                    + "\(report.hud.resizeCountRecordingPhase) > \(maximum)"
            )
        }
        if let expected = expect.settlementDuringStall,
            report.supervisor.settlementDuringStall != expected
        {
            failures.append(
                "expectation: settlementDuringStall \(report.supervisor.settlementDuringStall) != \(expected)"
            )
        }
        if let expected = expect.supervisorStopCalls,
            report.supervisor.stopCalls != expected
        {
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
        return failures
    }

    /// Checks the durable-checkpoint expectation.
    private static func journalExpectationFailures(
        _ expect: AgentScenario.Expect,
        report: AgentReport
    ) -> [String] {
        guard let minimum = expect.minCheckpointCount else { return [] }
        let count = report.journal?.checkpointCount ?? 0
        guard count < minimum else { return [] }
        return ["expectation: checkpointCount \(count) < \(minimum)"]
    }

    /// Checks the recovery and screen expectation groups.
    private func modeExpectationFailures(report: AgentReport) -> [String] {
        var failures: [String] = []
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
        return failures
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

    func record(_ event: String) {
        timeline.append(
            AgentReport.TimelineEntry(
                t: AgentHUDMetrics.milliseconds(from: origin, to: .now),
                event: event
            )
        )
    }

    /// Facts about the process that produced this report.
    private static func appFacts() -> AgentReport.AppFacts {
        AgentReport.AppFacts(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            signedIdentity: signingIdentity(),
            executablePath: Bundle.main.executableURL?.path ?? "unknown"
        )
    }

    /// Reads the authority of the code signature that is currently running.
    private static func signingIdentity() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return "unknown" }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return "unknown" }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
            let commonName
        else { return "unknown" }
        return commonName as String
    }
}

extension AudioSourceMode {
    /// The name the agent report uses for this mode.
    var agentName: String {
        switch self {
        case .system: "system"
        case .microphone: "microphone"
        case .systemAndMicrophone: "systemAndMicrophone"
        case .none: "none"
        }
    }
}
