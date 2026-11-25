import Foundation

/// Applies a screen scenario's expectations to one run's facts.
///
/// Kept outside `AgentRunner` (which owns the run) because these are pure value
/// checks: durations, counts, tracks, and the presented message.
enum AgentScreenExpectation {
    /// Evaluates every `screenExpect` assertion.
    ///
    /// - Parameters:
    ///   - expect: The scenario's screen expectations.
    ///   - screen: The facts collected from the run.
    ///   - screenSeconds: The seconds of video the scenario asked for.
    /// - Returns: One message per failed expectation; empty when all pass.
    static func evaluate(
        _ expect: AgentScreenExpect,
        screen: AgentReport.ScreenFacts,
        screenSeconds: Double
    ) -> [String] {
        var failures = evaluateMedia(expect, screen: screen, screenSeconds: screenSeconds)
        failures.append(contentsOf: evaluateAudioAndMessages(expect, screen: screen))
        return failures
    }

    /// Checks writer, publication, chunk, and duration expectations.
    private static func evaluateMedia(
        _ expect: AgentScreenExpect,
        screen: AgentReport.ScreenFacts,
        screenSeconds: Double
    ) -> [String] {
        var failures: [String] = []
        if let expected = expect.writerStart, screen.writerStart != expected {
            failures.append("expectation: screen.writerStart \(screen.writerStart) != \(expected)")
        }
        if let expected = expect.published, screen.published != expected {
            failures.append("expectation: screen.published \(screen.published) != \(expected)")
        }
        if let expected = expect.becameWaitingForFrame,
            screen.becameWaitingForFrame != expected
        {
            failures.append(
                "expectation: screen.becameWaitingForFrame \(screen.becameWaitingForFrame) != \(expected)"
            )
        }
        if let minimum = expect.minChunkBytes, screen.chunkBytes < minimum {
            failures.append("expectation: screen.chunkBytes \(screen.chunkBytes) < \(minimum)")
        }
        if let maximum = expect.maxChunkCount, screen.chunkCount > maximum {
            failures.append("expectation: screen.chunkCount \(screen.chunkCount) > \(maximum)")
        }
        if expect.noZeroByteChunks == true, screen.zeroByteChunkCount > 0 {
            failures.append(
                "expectation: \(screen.zeroByteChunkCount) zero-byte chunk(s) left behind"
            )
        }
        if let tolerance = expect.durationToleranceSeconds {
            let duration = screen.artifactDuration ?? 0
            if abs(duration - screenSeconds) > tolerance {
                failures.append(
                    "expectation: screen duration \(duration)s differs from \(screenSeconds)s "
                        + "by more than \(tolerance)s"
                )
            }
        }
        return failures
    }

    /// Checks audio-track, audio-start, and failure-message expectations.
    private static func evaluateAudioAndMessages(
        _ expect: AgentScreenExpect,
        screen: AgentReport.ScreenFacts
    ) -> [String] {
        var failures: [String] = []
        if expect.failureMentionsSystemSettings == true,
            screen.failureMessage != AppLocalization.string(ScreenCapturePermissionCopy.deniedKey)
        {
            failures.append(
                "expectation: failure does not name the screen-recording setting: "
                    + "\(screen.failureMessage ?? "none")"
            )
        }
        if let expected = expect.audioTrackPresent, screen.audioTrackPresent != expected {
            failures.append(
                "expectation: screen.audioTrackPresent \(screen.audioTrackPresent) != \(expected)"
            )
        }
        if let expected = expect.audioStartFailed, screen.audioStartFailed != expected {
            failures.append(
                "expectation: screen.audioStartFailed \(screen.audioStartFailed) != \(expected)"
            )
        }
        if expect.failureMentionsMissingAudio == true {
            let template = AppLocalization.string(
                "The system audio could not be recorded. The video was saved: %@"
            )
            let prefix = template.components(separatedBy: "%@").first ?? template
            if !(screen.failureMessage?.hasPrefix(prefix) ?? false) {
                failures.append(
                    "expectation: message does not report missing audio: "
                        + "\(screen.failureMessage ?? "none")"
                )
            }
        }
        return failures
    }
}
