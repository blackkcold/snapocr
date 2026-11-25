import Foundation

/// Whether the export selection references a segment whose media is missing.
public enum MissingState: Equatable, Sendable {
    /// Every selected segment has usable media.
    case none
    /// The selected segment with this identifier has no media on disk.
    case missing(segmentID: UUID)
}

/// What an export selection will produce, as shown in the export sheet.
///
/// The summary is built from an ``ExportAssessment`` and the recording session,
/// so the sheet reports the requested and effective durations, the operation
/// chosen for each track, and any segment the user still has to locate.
public struct RecordingExportSummary: Sendable, Equatable {
    /// Requested export duration in seconds, before trimming to the maximum.
    public let selectedDuration: TimeInterval
    /// Longest export the recorder allows, in seconds.
    public let maximumDuration: TimeInterval
    /// Seconds by which the selection exceeds the maximum; zero when it fits.
    public let overage: TimeInterval
    /// Localization key naming the video path, such as passthrough or audio only.
    public let videoPassthroughLabel: String
    /// Localization key naming how audio is produced, such as passthrough or re-encode.
    public let audioOperationLabel: String
    /// Number of tracks the export writes, including the video track when it is copied through.
    public let trackCount: Int
    /// Whether a selected segment is missing, and which one.
    public let missingState: MissingState

    /// Creates a summary, clamping durations and the track count to nonnegative values.
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
