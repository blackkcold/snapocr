import CaptureCore
import Foundation
import HistoryCore
import LibraryCore

/// One recording destination root scanned by the library and CLI.
///
/// This is the package-level equivalent of the App's `RecordingExportRoot`.
public struct LibraryRoot: Sendable, Hashable {
    public let kind: RecordingKind
    public let root: URL
    public let indexURL: URL

    public init(kind: RecordingKind, root: URL, indexURL: URL? = nil) {
        let standardizedRoot = root.standardizedFileURL
        self.kind = kind
        self.root = standardizedRoot
        self.indexURL = indexURL?.standardizedFileURL
            ?? standardizedRoot
                .appendingPathComponent(".SnapGlassSessions", isDirectory: true)
                .appendingPathComponent("recording-index.json")
    }
}

// MARK: - Unified presentation models

public enum LibraryMediaKind: String, Sendable, CaseIterable {
    case screenshot
    case audio
    case video
}

public enum LibraryViewMode: String, Sendable, CaseIterable {
    case list
    case grid
}

public enum LibraryRecordingState: Sendable, Equatable {
    case complete
    case partial(missing: Int)
    case offline

    public var missingCount: Int {
        if case .partial(let count) = self { return count }
        return 0
    }

    public var filterValue: LibraryStatusFilter {
        switch self {
        case .complete: .complete
        case .partial: .partial
        case .offline: .offline
        }
    }
}

public struct LibraryRecordingSegment: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let index: Int
    public let duration: TimeInterval
    public let byteSize: Int64
    public let state: PublishedSegmentState
    public let mediaURLs: [URL]
    public let videoURL: URL?
    public let audioURL: URL?
    public let audioRoles: [String]
    public let missingRangeCount: Int
    public let isAdopted: Bool
    public let sessionID: UUID
    public let root: URL?

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

    public var isAvailable: Bool { state == .published && !mediaURLs.isEmpty }
    public var displayIndex: Int { index + 1 }
}

public struct LibraryRecordingGroup: Identifiable, Sendable {
    public let id: String
    public let sessionID: UUID
    public let kind: RecordingKind
    public let layout: AudioOutputLayout
    public let title: String
    public let startedAt: Date
    public let duration: TimeInterval
    public let byteSize: Int64
    public let segments: [LibraryRecordingSegment]
    public let state: LibraryRecordingState
    public let isFavourite: Bool
    public let tags: [String]
    public let note: String?
    public let coverURL: URL?
    public let mediaURL: URL?
    public let roots: [URL]
    public let manualGroupID: UUID?
    public let memberSessionIDs: [UUID]

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

    public var mediaKind: LibraryMediaKind {
        kind == .audio ? .audio : .video
    }

    public var segmentCount: Int { segments.count }
    public var missingSegmentCount: Int { state.missingCount }
    public var isGrouped: Bool { segments.count > 1 }
    public var isManualGroup: Bool { manualGroupID != nil }
    public var isAvailable: Bool { state != .offline }

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

public enum LibraryItem: Identifiable, Sendable {
    case screenshot(HistoryEntry)
    case recording(LibraryRecordingGroup)

    public var id: String {
        switch self {
        case .screenshot(let entry):
            return "shot:\(entry.id.uuidString)"
        case .recording(let group):
            return group.id
        }
    }

    public var date: Date {
        switch self {
        case .screenshot(let entry): entry.timestamp
        case .recording(let group): group.startedAt
        }
    }

    public var mediaKind: LibraryMediaKind {
        switch self {
        case .screenshot: .screenshot
        case .recording(let group): group.mediaKind
        }
    }

    public var isFavourite: Bool {
        switch self {
        case .screenshot(let entry): entry.isFavourite
        case .recording(let group): group.isFavourite
        }
    }

    public var duration: TimeInterval? {
        switch self {
        case .screenshot: nil
        case .recording(let group): group.duration
        }
    }

    public var byteSize: Int64? {
        switch self {
        case .screenshot: nil
        case .recording(let group): group.byteSize
        }
    }

    public var recordingGroup: LibraryRecordingGroup? {
        if case .recording(let group) = self { return group }
        return nil
    }

    public var screenshot: HistoryEntry? {
        if case .screenshot(let entry) = self { return entry }
        return nil
    }

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

public struct LibraryDaySection: Identifiable {
    public let id: String
    public let date: Date
    public let items: [LibraryItem]

    public init(id: String, date: Date, items: [LibraryItem]) {
        self.id = id
        self.date = date
        self.items = items
    }
}

public struct RecordingLibrarySnapshot: Sendable {
    public let groups: [LibraryRecordingGroup]
    /// Automatic one-session groups before manual groups are projected.
    public let sessionGroups: [LibraryRecordingGroup]
    public let recoverable: [RecoverableRecording]
    public let offlineRoots: [String]
    public let totalBytes: Int64
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
