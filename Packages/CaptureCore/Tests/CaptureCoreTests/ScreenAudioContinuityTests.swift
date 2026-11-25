import Foundation
import Testing

@testable import CaptureCore

/// Regression tests for the screen audio path.
///
/// The screen system-audio source is a ring facade over the shared SCK stream. Its
/// generation is already active when the route controller prepares it, so the
/// initial commit must succeed; returning false failed every screen recording with
/// "initial route commit failed" before any audio was written.
@Suite("Screen audio continuity")
struct ScreenAudioContinuityTests {
    @Test("The ring source commits its own generation and rejects foreign ones")
    func ringSourceCommitsItsOwnGeneration() async throws {
        let ticks = AudioSourceTimestampMapper.nativeHostTicksPerSecond()
        let ring = try AudioSourceRingBuffer(
            role: .system,
            sampleRate: 48_000,
            channelCount: 2,
            hostTicksPerSecond: ticks
        )
        let source = ScreenRingAudioFrameSource(ring: ring, hostTicksPerSecond: ticks)

        let generation = await source.currentGeneration()
        #expect(await source.commitReconfiguration(generation))

        let foreign = AudioSourceGeneration(
            role: .system,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: 2),
            ringBuffer: ring
        )
        #expect(await source.commitReconfiguration(foreign) == false)

        await source.stop()
        #expect(await source.commitReconfiguration(generation) == false)
    }

    @Test("A missing audio track never marks a published video as failed")
    func audioFailureKeepsTheVideoSaved() {
        let outcome = ScreenRecordingOutcome(
            sessionID: UUID(),
            segmentURLs: [URL(fileURLWithPath: "/tmp/screen-recording.mp4")],
            droppedFrameCount: 0,
            failure: nil,
            audioFailure: "audio engine unavailable"
        )

        #expect(outcome.isSaved)
        #expect(outcome.failure == nil)
        #expect(outcome.audioFailure == "audio engine unavailable")
    }
}
