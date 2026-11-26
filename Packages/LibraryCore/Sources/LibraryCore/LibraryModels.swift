import CaptureCore
import Foundation
import HistoryCore
import LibraryCore

/// One recording destination root scanned by the library and CLI.
///
/// This is the package-level equivalent of the App's `RecordingExportRoot`.
public struct LibraryRoot: Sendable, Hashable {
    /// Kind of recording stored under this root.
    public let kind: RecordingKind
    /// Standardized URL of the destination root.
    public let root: URL
    /// Standardized URL of the session index used to discover recordings.
    public let indexURL: URL

    /// Creates a root, standardizing the given URLs.
    ///
    /// - Parameters:
    ///   - kind: Kind of recording stored under the root.
    ///   - root: Destination root that contains published recordings.
    ///   - indexURL: Session index to read; defaults to
    ///     `.SnapGlassSessions/recording-index.json` inside `root`.
    public init(kind: RecordingKind, root: URL, indexURL: URL? = nil) {
        let standardizedRoot = root.standardizedFileURL
        self.kind = kind
        self.root = standardizedRoot
        self.indexURL =
            indexURL?.standardizedFileURL
            ?? standardizedRoot
            .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
            .appendingPathComponent("recording-index.json")
    }
}

// MARK: - Unified presentation models

/// Media kind presented by an item in the unified library.
public enum LibraryMediaKind: String, Sendable, CaseIterable {
    case screenshot
    case audio
    case video
}

/// Presentation mode of the unified library.
public enum LibraryViewMode: String, Sendable, CaseIterable {
    case list
    case grid
}

/// Completeness of the published media of a recording group.
public enum LibraryRecordingState: Sendable, Equatable {
    case complete
    case partial(missing: Int)
    case offline

    /// Number of missing segments; `0` unless the state is `partial`.
    public var missingCount: Int {
        if case .partial(let count) = self { return count }
        return 0
    }

    /// Equivalent value of the status filter used by `LibraryFilter`.
    public var filterValue: LibraryStatusFilter {
        switch self {
        case .complete: .complete
        case .partial: .partial
        case .offline: .offline
        }
    }
}

/// One published or missing segment of a recording session.
public struct LibraryRecordingSegment: Identifiable, Sendable, Hashable {
    /// Stable identifier of the segment.
    public let id: UUID
    /// Zero-based position of the segment inside its session.
    public let index: Int
    /// Duration of the segment in seconds.
    public let duration: TimeInterval
    /// Total size of the segment's media files in bytes.
    public let byteSize: Int64
    /// Publication state reported by the capture layer.
    public let state: PublishedSegmentState
    /// Media files that make up the segment, in playback order.
    public let mediaURLs: [URL]
    /// Video file of the segment, if it has one.
    public let videoURL: URL?
    /// Primary audio file of the segment, if it has one.
    public let audioURL: URL?
    /// Audio track roles contained in the segment.
    public let audioRoles: [String]
    /// Number of time ranges the capture layer could not record.
    public let missingRangeCount: Int
    /// Whether the segment was adopted from an existing file instead of captured.
    public let isAdopted: Bool
    /// Identifier of the session that owns the segment.
    public let sessionID: UUID
    /// Destination root the segment was discovered under, if known.
    public let root: URL?

    /// Creates a segment with the given values.
    ///
    /// - Parameters:
    ///   - id: Stable identifier of the segment.
    ///   - index: Zero-based position inside the session.
    ///   - duration: Duration in seconds.
    ///   - byteSize: Total size of the media files in bytes.
    ///   - state: Publication state reported by the capture layer.
    ///   - mediaURLs: Media files in playback order.
    ///   - videoURL: Video file, if any.
    ///   - audioURL: Primary audio file, if any.
    ///   - audioRoles: Audio track roles contained in the segment.
    ///   - missingRangeCount: Number of unrecorded time ranges.
    ///   - isAdopted: Whether the segment came from an existing file.
    ///   - sessionID: Identifier of the owning session.
    ///   - root: Destination root, if known.
    public init(
        id: UUID,
        index: Int,
        duration: TimeInterval,
        byteSize: Int64,
        state: PublishedSegmentState,
        mediaURLs: [URL],
        videoURL: URL?,
        audioURL: URL?,
        audioRoles: [String],
        missingRangeCount: Int,
        isAdopted: Bool,
        sessionID: UUID,
        root: URL?
    ) {
        self.id = id
        self.index = index
        self.duration = duration
        self.byteSize = byteSize
        self.state = state
        self.mediaURLs = mediaURLs
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.audioRoles = audioRoles
        self.missingRangeCount = missingRangeCount
        self.isAdopted = isAdopted
        self.sessionID = sessionID
        self.root = root
    }

    /// Whether the segment is published and has at least one media file.
    public var isAvailable: Bool { state == .published && !mediaURLs.isEmpty }
    /// One-based position of the segment for display.
    public var displayIndex: Int { index + 1 }
}

/// One row of the unified library: an automatic session group or a manual group.
///
/// A manual group is a presentation-level composition of several sessions; its
/// segments are the concatenated segments of the member sessions.
public struct LibraryRecordingGroup: Identifiable, Sendable {
    /// Stable identifier, prefixed `rec:` for session groups and `group:` for
    /// manual groups.
    public let id: String
    /// Identifier of the session that represents the group.
    public let sessionID: UUID
    /// Kind of recording the group contains.
    public let kind: RecordingKind
    /// Audio output layout used when the group was recorded.
    public let layout: AudioOutputLayout
    /// User-visible title.
    public let title: String
    /// Start time of the earliest segment in the group.
    public let startedAt: Date
    /// Total duration of the group in seconds.
    public let duration: TimeInterval
    /// Total size of the group's media in bytes.
    public let byteSize: Int64
    /// Segments in playback order.
    public let segments: [LibraryRecordingSegment]
    /// Completeness of the group's published media.
    public let state: LibraryRecordingState
    /// Whether the user marked the group as a favourite.
    public let isFavourite: Bool
    /// Free-form tags attached to the group.
    public let tags: [String]
    /// Free-form note attached to the group, if any.
    public let note: String?
    /// Thumbnail or poster image for the group, if any.
    public let coverURL: URL?
    /// Primary media file for the group, if any.
    public let mediaURL: URL?
    /// Destination roots the group's segments were discovered under.
    public let roots: [URL]
    /// Manual group that composes this row, or `nil` for an automatic session
    /// group.
    public let manualGroupID: UUID?
    /// Sessions composed into this row; one element for automatic groups.
    public let memberSessionIDs: [UUID]

    /// Creates a group with the given values.
    ///
    /// - Parameters:
    ///   - sessionID: Identifier of the representative session.
    ///   - kind: Kind of recording.
    ///   - layout: Audio output layout the group was recorded with.
    ///   - title: User-visible title.
    ///   - startedAt: Start time of the earliest segment.
    ///   - duration: Total duration in seconds.
    ///   - byteSize: Total size of the media in bytes.
    ///   - segments: Segments in playback order.
    ///   - state: Completeness of the published media.
    ///   - isFavourite: Whether the group is a favourite.
    ///   - tags: Tags attached to the group.
    ///   - note: Note attached to the group, if any.
    ///   - coverURL: Thumbnail or poster image, if any.
    ///   - mediaURL: Primary media file, if any.
    ///   - roots: Destination roots that contain the group's media.
    ///   - manualGroupID: Manual group composing this row, if any.
    ///   - memberSessionIDs: Sessions composed into this row; defaults to
    ///     `sessionID`.
    public init(
        sessionID: UUID,
        kind: RecordingKind,
        layout: AudioOutputLayout,
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        byteSize: Int64,
        segments: [LibraryRecordingSegment],
        state: LibraryRecordingState,
        isFavourite: Bool,
        tags: [String],
        note: String?,
        coverURL: URL?,
        mediaURL: URL?,
        roots: [URL],
        manualGroupID: UUID? = nil,
        memberSessionIDs: [UUID]? = nil
    ) {
        self.id = manualGroupID.map { "group:\($0.uuidString)" } ?? "rec:\(sessionID.uuidString)"
        self.sessionID = sessionID
        self.kind = kind
        self.layout = layout
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.byteSize = byteSize
        self.segments = segments
        self.state = state
        self.isFavourite = isFavourite
        self.tags = tags
        self.note = note
        self.coverURL = coverURL
        self.mediaURL = mediaURL
        self.roots = roots
        self.manualGroupID = manualGroupID
        self.memberSessionIDs = memberSessionIDs ?? [sessionID]
    }

    /// Media kind presented for the group; audio recordings map to `.audio` and
    /// everything else to `.video`.
    public var mediaKind: LibraryMediaKind {
        kind == .audio ? .audio : .video
    }

    /// Number of segments in the group.
    public var segmentCount: Int { segments.count }
    /// Number of missing segments reported by the group state.
    public var missingSegmentCount: Int { state.missingCount }
    /// Whether the group contains more than one segment.
    public var isGrouped: Bool { segments.count > 1 }
    /// Whether the row was composed from a user-created manual group.
    public var isManualGroup: Bool { manualGroupID != nil }
    /// Whether the group's media is available; offline groups are not.
    public var isAvailable: Bool { state != .offline }

    /// Returns a copy with the favourite flag replaced.
    ///
    /// - Parameter value: Favourite flag for the copy.
    /// - Returns: A group with the same contents and the new flag.
    public func withFavourite(_ value: Bool) -> LibraryRecordingGroup {
        LibraryRecordingGroup(
            sessionID: sessionID,
            kind: kind,
            layout: layout,
            title: title,
            startedAt: startedAt,
            duration: duration,
            byteSize: byteSize,
            segments: segments,
            state: state,
            isFavourite: value,
            tags: tags,
            note: note,
            coverURL: coverURL,
            mediaURL: mediaURL,
            roots: roots,
            manualGroupID: manualGroupID,
            memberSessionIDs: memberSessionIDs
        )
    }

    /// Returns a copy with the title replaced.
    ///
    /// - Parameter value: Title for the copy.
    /// - Returns: A group with the same contents and the new title.
    public func withTitle(_ value: String) -> LibraryRecordingGroup {
        LibraryRecordingGroup(
            sessionID: sessionID,
            kind: kind,
            layout: layout,
            title: value,
            startedAt: startedAt,
            duration: duration,
            byteSize: byteSize,
            segments: segments,
            state: state,
            isFavourite: isFavourite,
            tags: tags,
            note: note,
            coverURL: coverURL,
            mediaURL: mediaURL,
            roots: roots,
            manualGroupID: manualGroupID,
            memberSessionIDs: memberSessionIDs
        )
    }

    /// Returns a copy with the tags replaced.
    ///
    /// - Parameter value: Tags for the copy.
    /// - Returns: A group with the same contents and the new tags.
    public func withTags(_ value: [String]) -> LibraryRecordingGroup {
        LibraryRecordingGroup(
            sessionID: sessionID,
            kind: kind,
            layout: layout,
            title: title,
            startedAt: startedAt,
            duration: duration,
            byteSize: byteSize,
            segments: segments,
            state: state,
            isFavourite: isFavourite,
            tags: value,
            note: note,
            coverURL: coverURL,
            mediaURL: mediaURL,
            roots: roots,
            manualGroupID: manualGroupID,
            memberSessionIDs: memberSessionIDs
        )
    }

    /// Returns a copy with the note replaced.
    ///
    /// - Parameter value: Note for the copy, or `nil` to remove it.
    /// - Returns: A group with the same contents and the new note.
    public func withNote(_ value: String?) -> LibraryRecordingGroup {
        LibraryRecordingGroup(
            sessionID: sessionID,
            kind: kind,
            layout: layout,
            title: title,
            startedAt: startedAt,
            duration: duration,
            byteSize: byteSize,
            segments: segments,
            state: state,
            isFavourite: isFavourite,
            tags: tags,
            note: value,
            coverURL: coverURL,
            mediaURL: mediaURL,
            roots: roots,
            manualGroupID: manualGroupID,
            memberSessionIDs: memberSessionIDs
        )
    }
}

/// A row in the unified library: either a screenshot or a recording group.
public enum LibraryItem: Identifiable, Sendable {
    case screenshot(HistoryEntry)
    case recording(LibraryRecordingGroup)

    /// Stable identifier, prefixed `shot:` for screenshots and taken from the
    /// recording group otherwise.
    public var id: String {
        switch self {
        case .screenshot(let entry):
            return "shot:\(entry.id.uuidString)"
        case .recording(let group):
            return group.id
        }
    }

    /// Sortable date: the capture time of a screenshot or the start time of a
    /// recording group.
    public var date: Date {
        switch self {
        case .screenshot(let entry): entry.timestamp
        case .recording(let group): group.startedAt
        }
    }

    /// Media kind presented by the item.
    public var mediaKind: LibraryMediaKind {
        switch self {
        case .screenshot: .screenshot
        case .recording(let group): group.mediaKind
        }
    }

    /// Whether the user marked the item as a favourite.
    public var isFavourite: Bool {
        switch self {
        case .screenshot(let entry): entry.isFavourite
        case .recording(let group): group.isFavourite
        }
    }

    /// Duration in seconds, or `nil` for screenshots.
    public var duration: TimeInterval? {
        switch self {
        case .screenshot: nil
        case .recording(let group): group.duration
        }
    }

    /// Size of the item's media in bytes, or `nil` for screenshots.
    public var byteSize: Int64? {
        switch self {
        case .screenshot: nil
        case .recording(let group): group.byteSize
        }
    }

    /// The recording group if the item is a recording, otherwise `nil`.
    public var recordingGroup: LibraryRecordingGroup? {
        if case .recording(let group) = self { return group }
        return nil
    }

    /// The screenshot entry if the item is a screenshot, otherwise `nil`.
    public var screenshot: HistoryEntry? {
        if case .screenshot(let entry) = self { return entry }
        return nil
    }

    /// Text searched by the library's text query.
    ///
    /// Includes recognised text, source app and window title, tags and, for
    /// recordings, the title, note and segment labels.
    public var searchText: String {
        switch self {
        case .screenshot(let entry):
            return [
                entry.textContent,
                entry.sourceAppName ?? "",
                entry.sourceWindowTitle ?? "",
                entry.tags.joined(separator: " "),
            ].joined(separator: " ")
        case .recording(let group):
            return [
                group.title,
                group.tags.joined(separator: " "),
                group.note ?? "",
                group.segments.map { "segment \($0.displayIndex)" }.joined(separator: " "),
            ].joined(separator: " ")
        }
    }
}

/// Library items grouped under one calendar day.
public struct LibraryDaySection: Identifiable {
    /// Stable identifier of the section.
    public let id: String
    /// Date that all items in the section belong to.
    public let date: Date
    /// Items in the section, in library order.
    public let items: [LibraryItem]

    /// Creates a section with the given values.
    ///
    /// - Parameters:
    ///   - id: Stable identifier of the section.
    ///   - date: Date shared by the items.
    ///   - items: Items in the section.
    public init(id: String, date: Date, items: [LibraryItem]) {
        self.id = id
        self.date = date
        self.items = items
    }
}

/// Result of one library scan.
public struct RecordingLibrarySnapshot: Sendable {
    /// Groups shown by the library, with manual groups projected.
    public let groups: [LibraryRecordingGroup]
    /// Automatic one-session groups before manual groups are projected.
    public let sessionGroups: [LibraryRecordingGroup]
    /// Sessions found on disk whose media could not be published.
    public let recoverable: [RecoverableRecording]
    /// Paths of roots that could not be read during the scan.
    public let offlineRoots: [String]
    /// Total size of the published media in bytes.
    public let totalBytes: Int64
    /// Time the scan completed.
    public let scannedAt: Date

    static let empty = RecordingLibrarySnapshot(
        groups: [],
        sessionGroups: [],
        recoverable: [],
        offlineRoots: [],
        totalBytes: 0,
        scannedAt: .distantPast
    )
}
