import Foundation

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
    ///   - bitRate: Configured audio bitrate in bits per second.
    ///   - videoBitsPerSecond: Nominal video bitrate in bits per second, if present.
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

/// Reads free capacity for an explicitly configured file URL.
public protocol VolumeCapacityProviding: Sendable {
    /// Returns free bytes for the volume containing `url`, or `nil` when unavailable.
    func availableBytes(at url: URL) throws -> Int64?
}

/// Production provider backed by Foundation's filesystem-volume attributes.
public struct URLVolumeCapacityProvider: VolumeCapacityProviding {
    /// Creates a provider that queries only the URL passed to ``availableBytes(at:)``.
    public init() {}

    /// Returns the filesystem's free bytes for the configured file URL.
    public func availableBytes(at url: URL) throws -> Int64? {
        guard url.isFileURL else { return nil }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let number = attributes[.systemFreeSize] as? NSNumber else { return nil }
        let capacity = number.int64Value
        return capacity >= 0 ? capacity : nil
    }
}

/// Failure raised when the storage configuration cannot be budgeted safely.
public enum RecordingSpaceBudgetError: Error, Equatable, Sendable {
    /// The media roles, channels, bitrates, or configured roots are invalid.
    case invalidConfiguration
}

struct RecordingVolumeCapacitySnapshot: Sendable {
    let availableBytes: Int64
    let reason: String?
}

/// A conservative, decimal-byte estimate for one recording and its safety reserve.
public struct RecordingSpaceBudget: Sendable {
    private static let sampleRate = 48_000
    private static let bytesPerSample = 2
    private static let maximumSegmentSeconds = 3_540.0
    private static let checkpointReserveSeconds = 300.0
    private static let tailReserveSeconds = 300.0

    private let configuration: RecordingStorageConfiguration
    private let capacityProvider: any VolumeCapacityProviding
    private let recordingRoot: URL
    private let recoveryRoot: URL

    /// Creates a budget over the recording and recovery volumes.
    ///
    /// Audio estimates use 48 kHz, 16-bit PCM and the configured channel count for
    /// every output role. Video bitrate is a nominal VBR estimate, not a hard cap.
    public init(
        configuration: RecordingStorageConfiguration,
        capacityProvider: any VolumeCapacityProviding,
        recordingRoot: URL,
        recoveryRoot: URL
    ) {
        self.configuration = configuration
        self.capacityProvider = capacityProvider
        self.recordingRoot = recordingRoot
        self.recoveryRoot = recoveryRoot
    }

    /// Estimates bytes for the requested duration using decimal bytes (GB = 1,000,000,000).
    /// Invalid durations/configurations and arithmetic overflow saturate to `Int64.max`.
    public func requiredBytes(seconds: TimeInterval) -> Int64 {
        guard let bytesPerSecond = estimatedBytesPerSecond,
              seconds.isFinite, seconds >= 0 else { return .max }
        let estimate = ceil(bytesPerSecond * seconds)
        guard estimate.isFinite, estimate >= 0, estimate < Double(Int64.max) else { return .max }
        return Int64(estimate)
    }

    /// Checks both configured volumes for one segment, its single seal output,
    /// the next checkpoint, and a tail reserve. No directory scan is performed.
    public func preflight() throws -> SpaceBudgetDecision {
        guard isValidConfiguration, recordingRoot.isFileURL, recoveryRoot.isFileURL else {
            throw RecordingSpaceBudgetError.invalidConfiguration
        }

        let segmentBytes = requiredBytes(seconds: Self.maximumSegmentSeconds)
        let checkpointAndTailBytes = requiredBytes(
            seconds: Self.checkpointReserveSeconds + Self.tailReserveSeconds
        )
        let required = Self.saturatedAdd(
            Self.saturatedAdd(segmentBytes, segmentBytes),
            checkpointAndTailBytes
        )
        let capacity = capacitySnapshot()
        let allowed = capacity.reason == nil && capacity.availableBytes >= required
        let reason: String?
        if let capacityReason = capacity.reason {
            reason = capacityReason
        } else if !allowed {
            reason = "recording or recovery volume has insufficient space"
        } else {
            reason = nil
        }
        return SpaceBudgetDecision(
            allowed: allowed,
            requiredBytes: required,
            availableBytes: capacity.availableBytes,
            reason: reason
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
        guard isValidConfiguration,
              availableBytes >= 0,
              nextCheckpointSeconds.isFinite, nextCheckpointSeconds >= 0,
              sealHeadroomSeconds.isFinite, sealHeadroomSeconds >= 0,
              tailReserveSeconds.isFinite, tailReserveSeconds >= 0 else { return true }
        let sealBytes = requiredBytes(seconds: sealHeadroomSeconds)
        let required = requiredHeadroomBytes(
            nextCheckpointSeconds: nextCheckpointSeconds,
            sealHeadroomBytes: sealBytes,
            tailReserveSeconds: tailReserveSeconds
        )
        return required == .max || availableBytes < required
    }

    func capacitySnapshot() -> RecordingVolumeCapacitySnapshot {
        var minimumAvailable: Int64?
        var failureReason: String?
        let volumes = [("recording", recordingRoot), ("recovery", recoveryRoot)]

        for (name, url) in volumes {
            guard url.isFileURL else {
                if failureReason == nil { failureReason = "\(name) volume URL is unavailable" }
                continue
            }
            do {
                guard let available = try capacityProvider.availableBytes(at: url), available >= 0 else {
                    if failureReason == nil { failureReason = "\(name) volume capacity is unavailable" }
                    continue
                }
                minimumAvailable = min(minimumAvailable ?? available, available)
            } catch {
                if failureReason == nil { failureReason = "\(name) volume capacity is unavailable" }
            }
        }

        return RecordingVolumeCapacitySnapshot(
            availableBytes: failureReason == nil ? (minimumAvailable ?? 0) : 0,
            reason: failureReason
        )
    }

    func requiredHeadroomBytes(
        nextCheckpointSeconds: TimeInterval,
        sealHeadroomBytes: Int64,
        tailReserveSeconds: TimeInterval
    ) -> Int64 {
        guard isValidConfiguration,
              nextCheckpointSeconds.isFinite, nextCheckpointSeconds >= 0,
              tailReserveSeconds.isFinite, tailReserveSeconds >= 0,
              sealHeadroomBytes >= 0 else { return .max }
        return Self.saturatedAdd(
            Self.saturatedAdd(
                requiredBytes(seconds: nextCheckpointSeconds),
                sealHeadroomBytes
            ),
            requiredBytes(seconds: tailReserveSeconds)
        )
    }

    private var isValidConfiguration: Bool {
        guard configuration.bitRate >= 0,
              configuration.videoBitsPerSecond.map({ $0 > 0 }) ?? true,
              configuration.channelCountByRole.values.allSatisfy({ $0 > 0 }) else { return false }

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

    private var estimatedBytesPerSecond: Double? {
        guard isValidConfiguration else { return nil }
        var channelCount: Int64 = 0
        for count in configuration.channelCountByRole.values {
            let (sum, overflow) = channelCount.addingReportingOverflow(Int64(count))
            guard !overflow else { return nil }
            channelCount = sum
        }
        let bytesPerChannelPerSecond = Int64(Self.sampleRate * Self.bytesPerSample)
        let (audioBytesPerSecond, channelOverflow) = channelCount.multipliedReportingOverflow(
            by: bytesPerChannelPerSecond
        )
        guard !channelOverflow else { return nil }
        let audioRate = Double(audioBytesPerSecond)
        let videoRate = configuration.videoBitsPerSecond.map { Double($0) / 8.0 } ?? 0
        let total = audioRate + videoRate
        return total.isFinite && total >= 0 ? total : nil
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs >= 0, rhs >= 0 else { return .max }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
