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

    @Test func preflightReadsOnlyRegisteredWriteRoots() throws {
        let provider = MutableCapacityProvider(defaultCapacity: 20_000_000_000)
        let storageBudget = budget(
            kind: .audio,
            layout: .mixed,
            channels: [.mixed: 2],
            bitRate: 128_000,
            provider: provider
        )

        let decision = try storageBudget.preflight()

        #expect(decision.allowed)
        #expect(decision.volumes.count == 1)
        #expect(provider.requestedPaths == ["/recording"])
        #expect(!provider.requestedPaths.contains("/recovery"))
    }

    @Test func sameVolumeWriteRootsMergeRequirements() throws {
        let provider = MutableCapacityProvider(defaultCapacity: nil)
        provider.set(capacity: 20_000, identity: 7, at: URL(fileURLWithPath: "/a"))
        provider.set(capacity: 12_000, identity: 7, at: URL(fileURLWithPath: "/b"))
        let storageBudget = RecordingSpaceBudget(
            configuration: audioConfiguration,
            capacityProvider: provider,
            writeRoots: [
                RecordingWriteRoot(url: URL(fileURLWithPath: "/a"), requiredBytes: 4_000),
                RecordingWriteRoot(url: URL(fileURLWithPath: "/b"), requiredBytes: 3_000),
            ]
        )

        let decision = try storageBudget.preflight()

        #expect(decision.allowed)
        #expect(decision.volumes.count == 1)
        #expect(decision.volumes[0].requiredBytes == 7_000)
        #expect(decision.volumes[0].availableBytes == 12_000)
    }

    @Test func differentVolumesShareTheirOwnRequirement() throws {
        let provider = MutableCapacityProvider(defaultCapacity: nil)
        provider.set(capacity: 10_000, identity: 7, at: URL(fileURLWithPath: "/a"))
        provider.set(capacity: 900, identity: 8, at: URL(fileURLWithPath: "/b"))
        let storageBudget = RecordingSpaceBudget(
            configuration: audioConfiguration,
            capacityProvider: provider,
            writeRoots: [
                RecordingWriteRoot(url: URL(fileURLWithPath: "/a"), requiredBytes: 4_000),
                RecordingWriteRoot(url: URL(fileURLWithPath: "/b"), requiredBytes: 3_000),
            ]
        )

        let decision = try storageBudget.preflight()

        #expect(!decision.allowed)
        #expect(decision.volumes.count == 2)
        #expect(decision.availableBytes == 900)
        #expect(decision.requiredBytes == 3_000)
        guard case let .insufficient(_, available, required)? = decision.denial else {
            Issue.record("Expected an insufficient-space denial")
            return
        }
        #expect(available == 900)
        #expect(required == 3_000)
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
        guard case .capacityUnreadable? = decision.denial else {
            Issue.record("Expected a capacity-unreadable denial")
            return
        }
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
        #expect(
            storageBudget.shouldStop(
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

        #expect(
            !storageBudget.shouldStop(
                availableBytes: required,
                nextCheckpointSeconds: 300,
                sealHeadroomSeconds: 60,
                tailReserveSeconds: 20
            ))
        #expect(
            storageBudget.shouldStop(
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
            recordingRoot: URL(fileURLWithPath: "/recording")
        )
        // 8,000 bits/s is estimated as 1,000 bytes/s; VBR may exceed this nominal estimate.
        #expect(videoBudget.requiredBytes(seconds: 10) == 10_000)
        #expect(
            videoBudget.shouldStop(
                availableBytes: 29_999,
                nextCheckpointSeconds: 10,
                sealHeadroomSeconds: 5,
                tailReserveSeconds: 15
            ))
        #expect(
            !videoBudget.shouldStop(
                availableBytes: 30_000,
                nextCheckpointSeconds: 10,
                sealHeadroomSeconds: 5,
                tailReserveSeconds: 15
            ))
    }

    private var audioConfiguration: RecordingStorageConfiguration {
        RecordingStorageConfiguration(
            kind: .audio,
            layout: .mixed,
            channelCountByRole: [.mixed: 2],
            bitRate: 128_000
        )
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
            recordingRoot: URL(fileURLWithPath: "/recording")
        )
    }
}

private final class MutableCapacityProvider: VolumeCapacityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var defaultCapacity: Int64?
    private var capacities: [String: Int64] = [:]
    private var identities: [String: RecordingVolumeIdentity] = [:]
    private var paths: [String] = []

    init(defaultCapacity: Int64?) {
        self.defaultCapacity = defaultCapacity
    }

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func availableBytes(at url: URL) throws -> Int64? {
        try volumeSnapshot(at: url)?.availableBytes
    }

    func volumeSnapshot(at url: URL) throws -> RecordingVolumeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        let path = url.standardizedFileURL.path
        paths.append(path)
        guard let capacity = capacities[path] ?? defaultCapacity else { return nil }
        return RecordingVolumeSnapshot(
            availableBytes: capacity,
            identity: identities[path]
        )
    }

    func set(capacity: Int64, identity: UInt64? = nil, at url: URL) {
        lock.lock()
        let path = url.standardizedFileURL.path
        capacities[path] = capacity
        if let identity {
            identities[path] = RecordingVolumeIdentity(systemNumber: identity)
        }
        lock.unlock()
    }
}
