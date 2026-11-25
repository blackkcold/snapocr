import AVFoundation
import Foundation

struct SendableMicrophoneAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    private let base: any MicrophoneAuthorizing

    init(_ base: any MicrophoneAuthorizing) { self.base = base }

    func currentState() -> MicrophoneAuthorizationState { base.currentState() }

    func requestAccess() async -> MicrophoneAuthorizationState { await base.requestAccess() }
}

/// Defers all native microphone input-node access until an authorized route starts.
actor LazyMicrophoneSource: AudioFrameSource, AudioSourceReconfigurationCancelling {
    nonisolated let role: RecordingTrackRole = .microphone
    private let authorizer: SendableMicrophoneAuthorizer
    private let hostTicksPerSecond: UInt64
    private let channelCount: Int
    private let placeholderGeneration: AudioSourceGeneration
    private var source: MicrophoneSource?

    init(authorizer: SendableMicrophoneAuthorizer, hostTicksPerSecond: UInt64, channelCount: Int) throws {
        let safeChannels = (1...2).contains(channelCount) ? channelCount : 1
        self.authorizer = authorizer
        self.hostTicksPerSecond = hostTicksPerSecond
        self.channelCount = safeChannels
        placeholderGeneration = try AudioSourceGeneration(
            role: .microphone,
            format: AudioSourceFormat(sampleRate: 48_000, channelCount: safeChannels),
            hostTicksPerSecond: hostTicksPerSecond
        )
    }

    func currentGeneration() async -> AudioSourceGeneration {
        if let source { return await source.currentGeneration() }
        return placeholderGeneration
    }

    func start() async throws {
        if let source {
            try await source.start()
            return
        }
        guard authorizer.currentState() == .authorized else {
            throw AudioSourceError.microphoneNotAuthorized(authorizer.currentState())
        }
        let capture = AVAudioEngineMicrophoneCaptureEngine()
        guard let format = capture.currentFormat,
              format.commonFormat == .pcmFormatFloat32,
              format.channelCount == 1 || format.channelCount == 2,
              format.sampleRate > 0
        else { throw AudioSourceError.invalidFormat }
        let sourceFormat = AudioSourceFormat(
            sampleRate: Int(format.sampleRate.rounded()),
            channelCount: Int(format.channelCount)
        )
        let ring = try AudioSourceRingBuffer(
            role: .microphone,
            sampleRate: sourceFormat.sampleRate,
            channelCount: sourceFormat.channelCount,
            hostTicksPerSecond: hostTicksPerSecond,
            capacitySeconds: 2.0
        )
        let nativeSource = MicrophoneSource(
            ringBuffer: ring,
            authorizer: authorizer,
            engine: capture,
            deviceMonitor: CoreAudioDeviceChangeMonitor(),
            format: sourceFormat,
            hostTicksPerSecond: hostTicksPerSecond
        )
        source = nativeSource
        try await nativeSource.start()
    }

    func isRunning() async -> Bool { await source?.isRunning() ?? false }

    func stop() async { await source?.stop() }

    func isProducerJoined() async -> Bool { await source?.isProducerJoined() ?? true }

    func prepareReconfiguration(_ event: AudioDeviceChangeEvent) async -> AudioSourcePreparation {
        guard let source else { return .unchangedOnFailure(reason: "microphone is not active") }
        return await source.prepareReconfiguration(event)
    }

    func commitReconfiguration(_ generation: AudioSourceGeneration) async -> Bool {
        guard let source else { return false }
        return await source.commitReconfiguration(generation)
    }

    func cancelReconfiguration(_ generationID: UUID) async {
        await source?.cancelReconfiguration(generationID)
    }
}
