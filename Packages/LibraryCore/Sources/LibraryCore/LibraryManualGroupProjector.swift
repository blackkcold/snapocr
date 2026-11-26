import Foundation

/// Projects automatic one-session groups plus user-created manual groups into
/// the groups shown by the library. A manual group is a presentation-level
/// composition; the underlying sessions are never merged or moved.
public enum LibraryManualGroupProjector {
    /// Projects manual groups over automatic session groups.
    ///
    /// Manual groups are processed in creation order and only those with at
    /// least two resolvable members of one recording kind are projected. A
    /// projected group concatenates its members' segments in start-time order,
    /// reports `.partial` when any member has missing segments, and carries the
    /// manual group's title and favourite flag. Sessions consumed by a manual
    /// group are not returned again; sessions without a manual group keep their
    /// automatic group and follow the projected ones.
    ///
    /// - Parameters:
    ///   - sessionGroups: Automatic one-session groups from the scan.
    ///   - manualGroups: User-created manual groups.
    /// - Returns: Groups to present, with manual groups first.
    public static func project(
        sessionGroups: [LibraryRecordingGroup],
        manualGroups: [RecordingManualGroup]
    ) -> [LibraryRecordingGroup] {
        var bySessionID = Dictionary(
            uniqueKeysWithValues: sessionGroups.map { ($0.sessionID, $0) }
        )
        var consumed = Set<UUID>()
        var projected: [LibraryRecordingGroup] = []

        for manual in manualGroups.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard manual.deletedAt == nil else { continue }
            let members = manual.sessionIDs.compactMap { bySessionID[$0] }
            guard members.count >= 2, let first = members.first else { continue }
            guard members.allSatisfy({ $0.kind == first.kind }) else { continue }

            let sortedMembers = members.sorted { $0.startedAt < $1.startedAt }
            let segments = sortedMembers.flatMap(\.segments)
            let missing = sortedMembers.reduce(0) { $0 + $1.missingSegmentCount }
            let roots = Array(Set(sortedMembers.flatMap(\.roots)))
                .sorted { $0.path < $1.path }
            let startedAt = sortedMembers.map(\.startedAt).min() ?? first.startedAt
            let coverURL = sortedMembers.compactMap(\.coverURL).first
            let mediaURL = sortedMembers.compactMap(\.mediaURL).first

            consumed.formUnion(sortedMembers.map(\.sessionID))
            projected.append(
                LibraryRecordingGroup(
                    sessionID: first.sessionID,
                    kind: first.kind,
                    layout: first.layout,
                    title: manual.title ?? first.title,
                    startedAt: startedAt,
                    duration: sortedMembers.reduce(0) { $0 + $1.duration },
                    byteSize: sortedMembers.reduce(Int64(0)) { $0 + $1.byteSize },
                    segments: segments,
                    state: missing > 0 ? .partial(missing: missing) : .complete,
                    isFavourite: manual.isFavourite,
                    tags: first.tags,
                    note: first.note,
                    coverURL: coverURL,
                    mediaURL: mediaURL,
                    roots: roots,
                    manualGroupID: manual.id,
                    memberSessionIDs: sortedMembers.map(\.sessionID)
                )
            )
        }

        projected.append(
            contentsOf: sessionGroups.filter { !consumed.contains($0.sessionID) }
        )
        return projected
    }
}
