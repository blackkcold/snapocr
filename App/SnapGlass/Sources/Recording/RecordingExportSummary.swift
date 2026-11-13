import Foundation

public enum MissingState: Equatable, Sendable {
    case none
    case missing(segmentID: UUID)
}

public struct RecordingExportSummary: Sendable, Equatable {
    public let selectedDuration: TimeInterval
    public let maximumDuration: TimeInterval
    public let overage: TimeInterval
    public let videoPassthroughLabel: String
    public let audioOperationLabel: String
    public let trackCount: Int
    public let missingState: MissingState

    public init(
        selectedDuration: TimeInterval,
        maximumDuration: TimeInterval,
        overage: TimeInterval,
        videoPassthroughLabel: String,
        audioOperationLabel: String,
        trackCount: Int,
        missingState: MissingState
    ) {
        self.selectedDuration = Self.nonnegativeFinite(selectedDuration)
        self.maximumDuration = Self.nonnegativeFinite(maximumDuration)
        self.overage = Self.nonnegativeFinite(overage)
        self.videoPassthroughLabel = videoPassthroughLabel
        self.audioOperationLabel = audioOperationLabel
        self.trackCount = max(0, trackCount)
        self.missingState = missingState
    }

    private static func nonnegativeFinite(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : 0
    }
}
