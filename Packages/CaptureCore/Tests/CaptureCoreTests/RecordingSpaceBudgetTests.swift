import Foundation
import Testing

@testable import CaptureCore

struct RecordingSpaceBudgetTests {
    @Test func requiredBytesMatchesDecimalGB() {
        let provider = MutableCapacityProvider(defaultCapacity: 20_000_000_000)
        let singleTrack = budget(
            kind: .audio,
            layout: .mixed,
            channels: [.mixed: 2],
            bitRate: 128_000,
            provider: provider
        )
        #expect(singleTrack.requiredBytes(seconds: 3_600) == 691_200_000)
        #expect(singleTrack.requiredBytes(seconds: 3_540) == 679_680_000)

        let multiTrack = budget(
            kind: .audio,
            layout: .separateTracks,
            channels: [.system: 2, .microphone: 1],
            bitRate: 192_000,
            provider: provider
        )
        #expect(multiTrack.requiredBytes(seconds: 3_600) == 1_036_800_000)
        #expect(multiTrack.requiredBytes(seconds: 3_540) == 1_019_520_000)
    }

    @Test func preflightChecksRecordingAndRecoveryVolumesSeparately() throws {
        let provider = MutableCapacityProvider(defaultCapacity: 3_000_000_000)
        let storageBudget = budget(
            kind: .audio,
            layout: .mixed,
            channels: [.mixed: 2],
            bitRate: 128_000,
            provider: provider
        )
        let required = try storageBudget.preflight().requiredBytes

        provider.set(required, at: storageBudget.recordingRootForTesting)
        provider.set(required, at: storageBudget.recoveryRootForTesting)
        #expect(try storageBudget.preflight().allowed)

        provider.set(required - 1, at: storageBudget.recordingRootForTesting)
        #expect(!(try storageBudget.preflight().allowed))

        provider.set(required, at: storageBudget.recordingRootForTesting)
        provider.set(required - 1, at: storageBudget.recoveryRootForTesting)
        #expect(!(try storageBudget.preflight().allowed))
    }

    @Test func capacityUnavailableFailsClosed() throws {
        let provider = MutableCapacityProvider(defaultCapacity: nil)
        let storageBudget = budget(
            kind: .audio,
            layout: .mixed,
            channels: [.mixed: 2],
            bitRate: 128_000,
            provider: provider
        )
        let decision = try storageBudget.preflight()
        #expect(!decision.allowed)
        #expect(decision.availableBytes == 0)
        #expect(decision.reason != nil)
    }

    @Test func invalidConfigurationDoesNotTrap() {
        let provider = MutableCapacityProvider(defaultCapacity: 20_000_000_000)
        let storageBudget = budget(
            kind: .audio,
            layout: .mixed,
            channels: [.mixed: 0],
            bitRate: 128_000,
            provider: provider
        )
        #expect(storageBudget.requiredBytes(seconds: 3_600) == .max)
        #expect(storageBudget.shouldStop(
            availableBytes: 20_000_000_000,
            nextCheckpointSeconds: 300,
            sealHeadroomSeconds: 60,
            tailReserveSeconds: 30
        ))
        do {
            _ = try storageBudget.preflight()
            Issue.record("Expected invalid storage configuration to be rejected")
        } catch RecordingSpaceBudgetError.invalidConfiguration {
            // Expected fail-closed result.
        } catch {
            Issue.record("Unexpected preflight error: \(error)")
        }
    }

    @Test func lowSpaceStopIncludesCheckpointSealAndTailReserve() {
        let storageBudget = budget(
            kind: .audio,
            layout: .mixed,
            channels: [.mixed: 2],
            bitRate: 128_000,
            provider: MutableCapacityProvider(defaultCapacity: 20_000_000_000)
        )
        let checkpoint = storageBudget.requiredBytes(seconds: 300)
        let seal = storageBudget.requiredBytes(seconds: 60)
        let tail = storageBudget.requiredBytes(seconds: 20)
        let required = checkpoint + seal + tail

        #expect(!storageBudget.shouldStop(
            availableBytes: required,
            nextCheckpointSeconds: 300,
            sealHeadroomSeconds: 60,
            tailReserveSeconds: 20
        ))
        #expect(storageBudget.shouldStop(
            availableBytes: required - 1,
            nextCheckpointSeconds: 300,
            sealHeadroomSeconds: 60,
            tailReserveSeconds: 20
        ))
    }

    @Test func videoEstimateUsesBitsPerSecondAndIsNotAnAbsoluteVBRCap() {
        let videoBudget = RecordingSpaceBudget(
            configuration: RecordingStorageConfiguration(
                kind: .screen,
                layout: .mixed,
                channelCountByRole: [:],
                bitRate: 0,
                videoBitsPerSecond: 8_000
            ),
            capacityProvider: MutableCapacityProvider(defaultCapacity: 20_000_000_000),
            recordingRoot: URL(fileURLWithPath: "/recording"),
            recoveryRoot: URL(fileURLWithPath: "/recovery")
        )
        // 8,000 bits/s is estimated as 1,000 bytes/s; VBR may exceed this nominal estimate.
        #expect(videoBudget.requiredBytes(seconds: 10) == 10_000)
        #expect(videoBudget.shouldStop(
            availableBytes: 29_999,
            nextCheckpointSeconds: 10,
            sealHeadroomSeconds: 5,
            tailReserveSeconds: 15
        ))
        #expect(!videoBudget.shouldStop(
            availableBytes: 30_000,
            nextCheckpointSeconds: 10,
            sealHeadroomSeconds: 5,
            tailReserveSeconds: 15
        ))
    }

    private func budget(
        kind: RecordingKind,
        layout: AudioOutputLayout,
        channels: [RecordingTrackRole: Int],
        bitRate: Int,
        provider: MutableCapacityProvider
    ) -> RecordingSpaceBudget {
        RecordingSpaceBudget(
            configuration: RecordingStorageConfiguration(
                kind: kind,
                layout: layout,
                channelCountByRole: channels,
                bitRate: bitRate
            ),
            capacityProvider: provider,
            recordingRoot: URL(fileURLWithPath: "/recording"),
            recoveryRoot: URL(fileURLWithPath: "/recovery")
        )
    }
}

private final class MutableCapacityProvider: VolumeCapacityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var defaultCapacity: Int64?
    private var capacities: [String: Int64] = [:]

    init(defaultCapacity: Int64?) {
        self.defaultCapacity = defaultCapacity
    }

    func availableBytes(at url: URL) throws -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return capacities[url.standardizedFileURL.path] ?? defaultCapacity
    }

    func set(_ capacity: Int64, at url: URL) {
        lock.lock()
        capacities[url.standardizedFileURL.path] = capacity
        lock.unlock()
    }
}

private extension RecordingSpaceBudget {
    var recordingRootForTesting: URL { URL(fileURLWithPath: "/recording") }
    var recoveryRootForTesting: URL { URL(fileURLWithPath: "/recovery") }
}
