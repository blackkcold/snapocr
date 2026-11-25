import CaptureCore
import CoreGraphics
import Foundation
import Testing

@Suite("Screen recording pipeline adapter")
struct ScreenRecordingPipelineAdapterTests {
    @Test("The app adapter builds a separate-track screen configuration from the selected mode")
    func appAdapterConstructsStartConfigurationAndComposition() {
        let source = RecordingSource.display(displayID: 12)
        let video = RecordingConfiguration(
            codec: .hevc,
            resolutionLimit: CGSize(width: 1_280, height: 720),
            frameRateLimit: 60,
            averageVideoBitrate: 12_000_000,
            maximumKeyFrameIntervalSeconds: 1,
            capturesSystemAudio: true
        )
        let excluded: Set<CGWindowID> = [41, 42]

        let configuration = ScreenRecordingPipelineAdapter.makeStartConfiguration(
            ScreenStartConfigurationInput(
                source: source,
                video: video,
                audioMode: .systemAndMicrophone,
                audioBitRate: 192_000,
                destinationDirectory: URL(fileURLWithPath: "/recordings"),
                excludedWindowIDs: excluded
            )
        )

        #expect(configuration.source == source)
        #expect(configuration.video.codec == .hevc)
        #expect(!configuration.video.capturesSystemAudio)
        #expect(configuration.audio.kind == .screen)
        #expect(configuration.audio.mode == .systemAndMicrophone)
        #expect(configuration.audio.layout == .separateTracks)
        #expect(configuration.audio.channelCountByRole == [.system: 2, .microphone: 1])
        #expect(configuration.audio.bitRate == 192_000)
        #expect(configuration.excludedWindowIDs == excluded)
    }

    @Test("A muted screen configuration has no fabricated audio tracks")
    func mutedScreenConfigurationHasNoAudioTracks() {
        let configuration = ScreenRecordingPipelineAdapter.makeStartConfiguration(
            ScreenStartConfigurationInput(
                source: .display(displayID: 12),
                video: RecordingConfiguration(),
                audioMode: .none,
                audioBitRate: 128_000,
                destinationDirectory: URL(fileURLWithPath: "/recordings"),
                excludedWindowIDs: []
            )
        )

        #expect(configuration.audio.mode == .none)
        #expect(configuration.audio.channelCountByRole.isEmpty)
        #expect(!configuration.video.capturesSystemAudio)
    }

    @Test("Adapter start, stop, and retry preserve the legacy save result shape")
    @MainActor
    func adapterStartStopRetryMatchesLegacyOutcome() async throws {
        let url = URL(fileURLWithPath: "/recordings/segment-00.mp4")
        let outcome = ScreenRecordingOutcome(
            sessionID: UUID(),
            segmentURLs: [url],
            droppedFrameCount: 0,
            failure: nil
        )
        var events: [String] = []
        let adapter = ScreenRecordingPipelineAdapter(
            start: { _, _ in events.append("start") },
            stopAndSave: {
                events.append("stop")
                return outcome
            },
            retryPublish: {
                events.append("retry")
                return url
            }
        )

        let configuration = ScreenRecordingPipelineAdapter.makeStartConfiguration(
            ScreenStartConfigurationInput(
                source: .display(displayID: 12),
                video: RecordingConfiguration(),
                audioMode: .system,
                audioBitRate: 128_000,
                destinationDirectory: URL(fileURLWithPath: "/recordings"),
                excludedWindowIDs: []
            )
        )
        try await adapter.start(configuration, onFailure: { _ in })
        let stopped = try await adapter.stopAndSave()
        let retriedURL = try await adapter.retryPublish()

        #expect(events == ["start", "stop", "retry"])
        #expect(stopped == outcome)
        #expect(stopped.latestPublishedURL == retriedURL)
        #expect(stopped.isSaved)
    }

    @Test("Quit takes precedence over capture actions")
    func quittingSelectsQuitAction() {
        #expect(
            ScreenRecordingPipelineDecision.action(
                canStart: true,
                canStop: true,
                canRetry: true,
                isQuitting: true
            ) == .quit
        )
    }

    @Test("Stop and retry actions take precedence over starting")
    func activeActionsTakePrecedenceOverStart() {
        #expect(
            ScreenRecordingPipelineDecision.action(
                canStart: true,
                canStop: true,
                canRetry: true,
                isQuitting: false
            ) == .stop
        )
        #expect(
            ScreenRecordingPipelineDecision.action(
                canStart: true,
                canStop: false,
                canRetry: true,
                isQuitting: false
            ) == .retry
        )
    }
}
