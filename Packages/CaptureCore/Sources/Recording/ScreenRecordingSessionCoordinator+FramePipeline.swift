import AudioToolbox
import Foundation
import SharedKit

extension ScreenRecordingSessionCoordinator {
    /// Appends one captured frame and starts the audio track on the first opportunity.
    func consume(_ event: ScreenVideoFrameEvent) async {
        guard let configuration, let composition, processingFailure == nil else {
            // The consumer stage: a consumed frame that cannot reach a writer.
            frameStreamDropCounter.increment()
            return
        }
        do {
            try await composition.coordinator.append(video: event.sampleBuffer, at: event.hostTime)
        } catch {
            frameStreamDropCounter.increment()
            logger.error("screen.session frame rejected: \(String(reflecting: error))")
            recordFailure(error.localizedDescription)
            return
        }
        guard audioEngine == nil, audioFailureReason == nil,
            configuration.audio.mode != .none,
            let epoch = await composition.coordinator.recordingEpochHostTime()
        else { return }
        do {
            let clock = AudioSampleClock(
                epochHostTime: epoch,
                hostTicksPerSecond: AudioSourceTimestampMapper.nativeHostTicksPerSecond(),
                sampleRate: configuration.audio.sampleRate
            )
            let engine = try audioEngineFactory(configuration.audio, composition.audioSink, clock)
            try await engine.start(configuration.audio)
            audioEngine = engine
        } catch {
            logger.error("screen.session audio start failed: \(String(reflecting: error))")
            recordAudioFailure(error.localizedDescription)
        }
    }

    /// Starts the one-second freeze-frame and boundary tick loop.
    func startBoundaryTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.advanceBoundaryTick()
            }
        }
    }

    func advanceBoundaryTick() async {
        guard !isStopping, processingFailure == nil, let composition else { return }
        do {
            try await composition.coordinator.tick(hostTime: AudioGetCurrentHostTime())
        } catch {
            recordFailure(error.localizedDescription)
        }
    }

    func recordFailure(_ reason: String) {
        guard processingFailure == nil else { return }
        processingFailure = reason
        logger.error("screen.session failure: \(reason)")
        onFailure?(reason)
    }

    /// Records an audio-start failure without stopping the video.
    ///
    /// The video writer, the freeze-frame ticks, and the boundary ticks keep
    /// running; the app tells the user the system audio was not captured when the
    /// file is saved. Audio is attempted once per session.
    ///
    /// - Parameter reason: The audio engine's failure description.
    func recordAudioFailure(_ reason: String) {
        guard audioFailureReason == nil else { return }
        audioFailureReason = reason
        logger.error("screen.session audio unavailable; the video keeps recording: \(reason)")
    }
}
