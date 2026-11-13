import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CaptureCore

struct ScreenAudioBridgeTests {
    @Test func systemAndMicrophoneBlocksFeedTheirOwnRings() throws {
        let systemRing = try makeRing(role: .system)
        let microphoneRing = try makeRing(role: .microphone)
        let bridge = ScreenAudioBridge(
            systemRing: systemRing,
            microphoneRing: microphoneRing,
            hostTicksPerSecond: 48_000
        )
        let systemBlock = block(role: .system, value: 0.25)
        let microphoneBlock = block(role: .microphone, value: -0.25)

        try bridge.appendSystem(systemBlock)
        try bridge.appendMicrophone(microphoneBlock)

        let system = systemRing.read(maxFrames: 480).block
        let microphone = microphoneRing.read(maxFrames: 480).block
        #expect(system?.role == .system)
        #expect(system?.channels.first?.first == 0.25)
        #expect(microphone?.role == .microphone)
        #expect(microphone?.channels.first?.first == -0.25)
    }

    @Test func callbackAcceptsSampleBufferDirectlyIntoSystemRing() throws {
        let ring = try makeRing(role: .system)
        let bridge = ScreenAudioBridge(
            systemRing: ring,
            microphoneRing: nil,
            hostTicksPerSecond: 48_000
        )
        let pcm = try AudioSampleBufferFactory.makePCMBuffer(
            channels: [[Float](repeating: 0.5, count: 480)],
            sampleRate: 48_000
        )
        let sampleBuffer = try AudioSampleBufferFactory.makeSampleBuffer(
            from: pcm,
            presentationTime: .zero
        )

        try bridge.appendSystem(sampleBuffer: sampleBuffer)
        let block = ring.read(maxFrames: 480).block
        #expect(block?.role == .system)
        #expect(block?.frameCount == 480)
        #expect(block?.channels.first?.first == 0.5)
    }

    @Test func microphoneAppendFailsWhenNoMicrophoneRingWasConfigured() throws {
        let bridge = ScreenAudioBridge(
            systemRing: try makeRing(role: .system),
            microphoneRing: nil,
            hostTicksPerSecond: 48_000
        )

        #expect(throws: ScreenAudioBridgeError.self) {
            try bridge.appendMicrophone(block(role: .microphone, value: 0))
        }
    }

    private func makeRing(role: RecordingTrackRole) throws -> AudioSourceRingBuffer {
        try AudioSourceRingBuffer(
            role: role,
            sampleRate: 48_000,
            channelCount: 1,
            hostTicksPerSecond: 48_000,
            capacitySeconds: 0.05
        )
    }

    private func block(role: RecordingTrackRole, value: Float) -> AudioPCMBlock {
        AudioPCMBlock(
            role: role,
            range: SampleRange(startSample: 0, sampleCount: 480),
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 480,
            hostTime: 48_000,
            channels: [[Float](repeating: value, count: 480)],
            isSilence: value == 0
        )
    }
}
