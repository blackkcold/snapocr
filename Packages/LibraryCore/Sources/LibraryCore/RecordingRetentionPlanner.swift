import Foundation

/// Pure policy for recording retention. The UI and CLI both use this so the
/// preview count and the actual cleanup can never disagree.
public enum RecordingRetentionPlanner {
    public static func eligibleGroups(
        _ groups: [LibraryRecordingGroup],
        olderThanDays days: Int,
        now: Date = Date()
    ) -> [LibraryRecordingGroup] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        return groups.filter { group in
            group.startedAt < cutoff
                && !group.isFavourite
                && group.state != .offline
        }
    }
}
