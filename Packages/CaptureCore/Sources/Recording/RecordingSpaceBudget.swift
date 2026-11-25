import Foundation
import SharedKit

/// Storage-related inputs used to estimate one recording's on-disk footprint.
public struct RecordingStorageConfiguration: Sendable, Hashable {
    /// The kind of media the recording produces.
    public let kind: RecordingKind
    /// The layout used for audio outputs.
    public let layout: AudioOutputLayout
    /// Audio channel count for each output role.
    public let channelCountByRole: [RecordingTrackRole: Int]
    /// Configured audio encoder bitrate, in bits per second.
    public let bitRate: Int
    /// Nominal video bitrate in bits per second, when video is present.
    public let videoBitsPerSecond: Int?

    /// Creates a storage configuration. Invalid values are rejected by the budget.
    ///
    /// - Parameters:
    ///   - kind: The kind of media the recording produces.
    ///   - layout: The audio output layout.
    ///   - channelCountByRole: Number of audio channels for each output role.
    ///   - bitRate: Configured audio bitrate, in bits per second.
    ///   - videoBitsPerSecond: Nominal video bitrate, in bits per second, if present.
    public init(
        kind: RecordingKind,
        layout: AudioOutputLayout,
        channelCountByRole: [RecordingTrackRole: Int],
        bitRate: Int,
        videoBitsPerSecond: Int? = nil
    ) {
        self.kind = kind
        self.layout = layout
        self.channelCountByRole = channelCountByRole
        self.bitRate = bitRate
        self.videoBitsPerSecond = videoBitsPerSecond
    }

    /// Creates storage inputs from the audio pipeline's immutable configuration.
    public init(audioConfiguration: AudioRecordingConfiguration) {
        self.init(
            kind: audioConfiguration.kind,
            layout: audioConfiguration.layout,
            channelCountByRole: audioConfiguration.channelCountByRole,
            bitRate: audioConfiguration.bitRate
        )
    }
}

/// A stable identity for one mounted filesystem volume.
///
/// The value is the filesystem's `systemNumber` read in the same
/// `attributesOfFileSystem` call that produced available bytes. It is valid for
/// one capacity decision only; do not persist it across requests or remounts.
public struct RecordingVolumeIdentity: Sendable, Hashable {
    /// The filesystem number that distinguishes mounted volumes.
    public let systemNumber: UInt64

    /// Creates an identity from one filesystem number.
    public init(systemNumber: UInt64) {
        self.systemNumber = systemNumber
    }
}

/// One capacity reading for a write root.
public struct RecordingVolumeSnapshot: Sendable, Hashable {
    /// Free bytes reported by the volume.
    public let availableBytes: Int64
    /// The volume that owns this reading, when the provider can report it.
    public let identity: RecordingVolumeIdentity?

    /// Creates a snapshot. Identity is optional for providers that cannot report it.
    public init(availableBytes: Int64, identity: RecordingVolumeIdentity? = nil) {
        self.availableBytes = availableBytes
        self.identity = identity
    }
}

/// Reads free capacity for an explicitly configured file URL.
public protocol VolumeCapacityProviding: Sendable {
    /// Returns free bytes for the volume containing `url`, or `nil` when unavailable.
    func availableBytes(at url: URL) throws -> Int64?

    /// Returns free bytes and volume identity from one filesystem read.
    ///
    /// The default implementation wraps ``availableBytes(at:)`` with a nil
    /// identity, so existing providers keep compiling.
    func volumeSnapshot(at url: URL) throws -> RecordingVolumeSnapshot?
}

public extension VolumeCapacityProviding {
    /// Default identity-less snapshot built from ``availableBytes(at:)``.
    func volumeSnapshot(at url: URL) throws -> RecordingVolumeSnapshot? {
        guard let bytes = try availableBytes(at: url), bytes >= 0 else { return nil }
        return RecordingVolumeSnapshot(availableBytes: bytes)
    }
}

/// Production provider backed by Foundation's filesystem-volume attributes.
public struct URLVolumeCapacityProvider: VolumeCapacityProviding {
    /// Creates a provider that queries only the URL passed to ``volumeSnapshot(at:)``.
    public init() {}

    /// Returns the filesystem's free bytes for the configured file URL.
    public func availableBytes(at url: URL) throws -> Int64? {
        try volumeSnapshot(at: url)?.availableBytes
    }

    /// Reads free bytes and the volume identity from one attribute lookup.
    public func volumeSnapshot(at url: URL) throws -> RecordingVolumeSnapshot? {
        guard url.isFileURL else { return nil }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let number = attributes[.systemFreeSize] as? NSNumber else { return nil }
        let capacity = number.int64Value
        guard capacity >= 0 else { return nil }
        let identity = (attributes[.systemNumber] as? NSNumber).map {
            RecordingVolumeIdentity(systemNumber: $0.uint64Value)
        }
        return RecordingVolumeSnapshot(availableBytes: capacity, identity: identity)
    }
}

/// Failure raised when the storage configuration cannot be budgeted safely.
public enum RecordingSpaceBudgetError: Error, Equatable, Sendable {
    /// The media roles, channels, bitrates, or configured roots are invalid.
    case invalidConfiguration
}

/// One root that actually receives bytes, with the bytes it needs on its volume.
struct RecordingWriteRoot: Sendable, Hashable {
    let url: URL
    let requiredBytes: Int64
}

/// One measured write volume after same-volume roots have been merged.
struct RecordingVolumeCapacitySnapshot: Sendable {
    struct Volume: Sendable, Hashable {
        let path: URL
        let identity: RecordingVolumeIdentity?
        let availableBytes: Int64
        let requiredBytes: Int64
    }

    let volumes: [Volume]
    let reason: String?

    /// Lowest available capacity across the measured write volumes.
    var availableBytes: Int64 {
        guard reason == nil else { return 0 }
        return volumes.map(\.availableBytes).min() ?? 0
    }
}

private struct RecordingVolumeCapacityReading: Sendable {
    let root: URL
    let identity: RecordingVolumeIdentity?
    let availableBytes: Int64
    let requiredBytes: Int64

    /// Same volume when identity matches; when identity is unavailable, only
    /// the exact standardized path is treated as the same root.
    var groupingKey: String {
        if let identity {
            return "volume:\(identity.systemNumber)"
        }
        return "path:\(root.standardizedFileURL.path)"
    }
}

/// A conservative, decimal-byte estimate for one recording and its safety reserve.
///
/// Only roots that actually receive bytes are part of the budget. A directory
/// with no writer (for example, the Application Support recovery folder) is not
/// passed in, is never probed, and cannot block a recording.
public struct RecordingSpaceBudget: Sendable {
    private static let sampleRate = 48_000
    private static let bytesPerSample = 2
    private static let maximumSegmentSeconds = 3_540.0
    private static let checkpointReserveSeconds = 300.0
    private static let tailReserveSeconds = 300.0

    private let configuration: RecordingStorageConfiguration
    private let capacityProvider: any VolumeCapacityProviding
    private let writeRoots: [RecordingWriteRoot]
    private let expectedVolumeUUID: String?

    /// Creates a budget for the destination that receives the recording.
    ///
    /// Audio estimates use 48 kHz, 16-bit PCM and the configured channel count for
    /// every output role. Video bitrate is a nominal VBR estimate, not a hard cap.
    ///
    /// - Parameters:
    ///   - configuration: The media configuration to estimate.
    ///   - capacityProvider: Reads free bytes and volume identity.
    ///   - recordingRoot: The directory that receives checkpoints and final media.
    public init(
        configuration: RecordingStorageConfiguration,
        capacityProvider: any VolumeCapacityProviding,
        recordingRoot: URL,
        expectedVolumeUUID: String? = nil
    ) {
        self.configuration = configuration
        self.capacityProvider = capacityProvider
        self.writeRoots = [
            RecordingWriteRoot(
                url: recordingRoot,
                requiredBytes: Self.minimumStartRequirement(for: configuration)
            )
        ]
        self.expectedVolumeUUID = expectedVolumeUUID
    }

    /// Creates a budget from explicitly registered write roots.
    ///
    /// Used by tests to prove same-volume merging and different-volume sharing.
    /// Production code passes only the destination that actually receives bytes.
    init(
        configuration: RecordingStorageConfiguration,
        capacityProvider: any VolumeCapacityProviding,
        writeRoots: [RecordingWriteRoot],
        expectedVolumeUUID: String? = nil
    ) {
        self.configuration = configuration
        self.capacityProvider = capacityProvider
        self.writeRoots = writeRoots
        self.expectedVolumeUUID = expectedVolumeUUID
    }

    /// Estimates bytes for the requested duration using decimal bytes (GB = 1,000,000,000).
    /// Invalid durations/configurations and arithmetic overflow saturate to `Int64.max`.
    public func requiredBytes(seconds: TimeInterval) -> Int64 {
        guard let bytesPerSecond = Self.estimatedBytesPerSecond(for: configuration) else {
            return .max
        }
        return Self.requiredBytes(seconds: seconds, bytesPerSecond: bytesPerSecond)
    }

    /// The start-time peak for this configuration: one segment, its single seal
    /// output, the next checkpoint reserve, and the final tail reserve.
    ///
    /// Settings pages call this so their requirement matches the start gate.
    public static func minimumStartRequirement(
        for configuration: RecordingStorageConfiguration
    ) -> Int64 {
        guard let bytesPerSecond = estimatedBytesPerSecond(for: configuration) else {
            return .max
        }
        let segmentBytes = requiredBytes(
            seconds: maximumSegmentSeconds,
            bytesPerSecond: bytesPerSecond
        )
        let checkpointAndTailBytes = requiredBytes(
            seconds: checkpointReserveSeconds + tailReserveSeconds,
            bytesPerSecond: bytesPerSecond
        )
        return saturatedAdd(saturatedAdd(segmentBytes, segmentBytes), checkpointAndTailBytes)
    }

    /// The start-time peak for this budget's configuration.
    public func minimumStartRequirement() -> Int64 {
        Self.minimumStartRequirement(for: configuration)
    }

    /// Checks every actual write volume for one segment, its single seal output,
    /// the next checkpoint, and a tail reserve. No directory scan is performed.
    ///
    /// A single write root produces a single capacity read. Additional write roots
    /// are each read once and then grouped by volume identity; same-volume
    /// requirements are summed without re-reading capacity for deduplication.
    public func preflight() throws -> SpaceBudgetDecision {
        guard Self.isValid(configuration), !writeRoots.isEmpty,
            writeRoots.allSatisfy({ $0.url.isFileURL })
        else {
            throw RecordingSpaceBudgetError.invalidConfiguration
        }

        let snapshot = capacitySnapshot()
        if let reason = snapshot.reason {
            let required = writeRoots.reduce(Int64(0)) {
                Self.saturatedAdd($0, $1.requiredBytes)
            }
            return SpaceBudgetDecision(
                allowed: false,
                requiredBytes: required,
                availableBytes: 0,
                reason: reason,
                volumes: snapshot.volumes.map { makePlan($0) },
                denial: .capacityUnreadable(role: .recording)
            )
        }

        let plans = snapshot.volumes.map { makePlan($0) }
        guard !plans.isEmpty else {
            throw RecordingSpaceBudgetError.invalidConfiguration
        }
        guard let binding = plans.first(where: { ($0.availableBytes ?? 0) < $0.requiredBytes }) else {
            let slackOwner = plans.min {
                (($0.availableBytes ?? 0) - $0.requiredBytes)
                    < (($1.availableBytes ?? 0) - $1.requiredBytes)
            }
            let owner = slackOwner ?? plans[0]
            return SpaceBudgetDecision(
                allowed: true,
                requiredBytes: owner.requiredBytes,
                availableBytes: owner.availableBytes ?? 0,
                reason: nil,
                volumes: plans
            )
        }

        let available = binding.availableBytes ?? 0
        return SpaceBudgetDecision(
            allowed: false,
            requiredBytes: binding.requiredBytes,
            availableBytes: available,
            reason: "recording volume has insufficient space",
            volumes: plans,
            denial: .insufficient(
                role: binding.role,
                available: available,
                required: binding.requiredBytes
            )
        )
    }

    /// Returns whether the available capacity cannot cover the next checkpoint,
    /// one seal output of the supplied duration, and the final tail reserve.
    public func shouldStop(
        availableBytes: Int64,
        nextCheckpointSeconds: TimeInterval,
        sealHeadroomSeconds: TimeInterval,
        tailReserveSeconds: TimeInterval
    ) -> Bool {
        guard Self.isValid(configuration),
            availableBytes >= 0,
            nextCheckpointSeconds.isFinite, nextCheckpointSeconds >= 0,
            sealHeadroomSeconds.isFinite, sealHeadroomSeconds >= 0,
            tailReserveSeconds.isFinite, tailReserveSeconds >= 0
        else { return true }
        let sealBytes = requiredBytes(seconds: sealHeadroomSeconds)
        let required = requiredHeadroomBytes(
            nextCheckpointSeconds: nextCheckpointSeconds,
            sealHeadroomBytes: sealBytes,
            tailReserveSeconds: tailReserveSeconds
        )
        return required == .max || availableBytes < required
    }

    /// Reads only the registered write roots and merges readings by volume.
    func capacitySnapshot() -> RecordingVolumeCapacitySnapshot {
        let result = readWriteRoots()
        return RecordingVolumeCapacitySnapshot(
            volumes: groupedVolumes(result.readings),
            reason: result.failureReason
        )
    }

    func requiredHeadroomBytes(
        nextCheckpointSeconds: TimeInterval,
        sealHeadroomBytes: Int64,
        tailReserveSeconds: TimeInterval
    ) -> Int64 {
        guard Self.isValid(configuration),
            nextCheckpointSeconds.isFinite, nextCheckpointSeconds >= 0,
            tailReserveSeconds.isFinite, tailReserveSeconds >= 0,
            sealHeadroomBytes >= 0
        else { return .max }
        return Self.saturatedAdd(
            Self.saturatedAdd(
                requiredBytes(seconds: nextCheckpointSeconds),
                sealHeadroomBytes
            ),
            requiredBytes(seconds: tailReserveSeconds)
        )
    }

    private func readWriteRoots() -> (
        readings: [RecordingVolumeCapacityReading],
        failureReason: String?
    ) {
        var readings: [RecordingVolumeCapacityReading] = []
        var failureReason: String?
        for writeRoot in writeRoots {
            guard writeRoot.url.isFileURL else {
                if failureReason == nil {
                    failureReason = "recording volume URL is unavailable"
                }
                continue
            }
            if let expectedVolumeUUID {
                guard let current = RecordingVolumeIdentityPolicy.volumeUUIDString(for: writeRoot.url),
                    current == expectedVolumeUUID
                else {
                    if failureReason == nil {
                        failureReason = "recording volume identity changed"
                    }
                    continue
                }
            } else if RecordingVolumeIdentityPolicy.isStaleVolumesMountPoint(writeRoot.url) {
                if failureReason == nil {
                    failureReason = "recording volume is a stale mount point"
                }
                continue
            }
            do {
                guard let snapshot = try capacityProvider.volumeSnapshot(at: writeRoot.url),
                    snapshot.availableBytes >= 0
                else {
                    if failureReason == nil {
                        failureReason = "recording volume capacity is unavailable"
                    }
                    continue
                }
                readings.append(
                    RecordingVolumeCapacityReading(
                        root: writeRoot.url,
                        identity: snapshot.identity,
                        availableBytes: snapshot.availableBytes,
                        requiredBytes: writeRoot.requiredBytes
                    )
                )
            } catch {
                if failureReason == nil {
                    failureReason = "recording volume capacity is unavailable"
                }
            }
        }
        return (readings, failureReason)
    }

    private func groupedVolumes(
        _ readings: [RecordingVolumeCapacityReading]
    ) -> [RecordingVolumeCapacitySnapshot.Volume] {
        var order: [String] = []
        var grouped: [String: RecordingVolumeCapacitySnapshot.Volume] = [:]

        for reading in readings {
            let key = reading.groupingKey
            if let existing = grouped[key] {
                grouped[key] = RecordingVolumeCapacitySnapshot.Volume(
                    path: existing.path,
                    identity: existing.identity,
                    availableBytes: min(existing.availableBytes, reading.availableBytes),
                    requiredBytes: Self.saturatedAdd(existing.requiredBytes, reading.requiredBytes)
                )
            } else {
                order.append(key)
                grouped[key] = RecordingVolumeCapacitySnapshot.Volume(
                    path: reading.root,
                    identity: reading.identity,
                    availableBytes: reading.availableBytes,
                    requiredBytes: reading.requiredBytes
                )
            }
        }
        return order.compactMap { grouped[$0] }
    }

    private func makePlan(
        _ volume: RecordingVolumeCapacitySnapshot.Volume
    ) -> RecordingVolumePlan {
        RecordingVolumePlan(
            role: .recording,
            path: volume.path,
            identity: volume.identity,
            requiredBytes: volume.requiredBytes,
            availableBytes: volume.availableBytes,
            isLocationAvailable: true
        )
    }

    private static func isValid(_ configuration: RecordingStorageConfiguration) -> Bool {
        guard configuration.bitRate >= 0,
            configuration.videoBitsPerSecond.map({ $0 > 0 }) ?? true,
            configuration.channelCountByRole.values.allSatisfy({ $0 > 0 })
        else { return false }

        let roles = Set(configuration.channelCountByRole.keys)
        switch configuration.layout {
        case .mixed:
            guard roles.isEmpty || roles == [.mixed] else { return false }
        case .separateTracks:
            guard !roles.contains(.mixed) else { return false }
        }

        if !roles.isEmpty && configuration.bitRate <= 0 { return false }
        if configuration.kind == .audio {
            guard !roles.isEmpty, configuration.videoBitsPerSecond == nil else { return false }
        } else if roles.isEmpty && configuration.videoBitsPerSecond == nil {
            return false
        }
        return true
    }

    private static func estimatedBytesPerSecond(
        for configuration: RecordingStorageConfiguration
    ) -> Double? {
        guard isValid(configuration) else { return nil }
        var channelCount: Int64 = 0
        for count in configuration.channelCountByRole.values {
            let (sum, overflow) = channelCount.addingReportingOverflow(Int64(count))
            guard !overflow else { return nil }
            channelCount = sum
        }
        let bytesPerChannelPerSecond = Int64(sampleRate * bytesPerSample)
        let (audioBytesPerSecond, channelOverflow) = channelCount.multipliedReportingOverflow(
            by: bytesPerChannelPerSecond
        )
        guard !channelOverflow else { return nil }
        let audioRate = Double(audioBytesPerSecond)
        let videoRate = configuration.videoBitsPerSecond.map { Double($0) / 8.0 } ?? 0
        let total = audioRate + videoRate
        return total.isFinite && total >= 0 ? total : nil
    }

    private static func requiredBytes(
        seconds: TimeInterval,
        bytesPerSecond: Double
    ) -> Int64 {
        guard seconds.isFinite, seconds >= 0 else { return .max }
        let estimate = ceil(bytesPerSecond * seconds)
        guard estimate.isFinite, estimate >= 0, estimate < Double(Int64.max) else { return .max }
        return Int64(estimate)
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs >= 0, rhs >= 0 else { return .max }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
