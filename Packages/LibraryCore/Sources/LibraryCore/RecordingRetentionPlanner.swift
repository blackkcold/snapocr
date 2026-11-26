import Foundation

/// Pure policy for recording retention. The UI and CLI both use this so the
/// preview count and the actual cleanup can never disagree.
public enum RecordingRetentionPlanner {
    /// Returns groups eligible for retention cleanup.
    ///
    /// A group is eligible when it started before `days` days ago, is not a
    /// favourite and is not offline.
    ///
    /// - Parameters:
    ///   - groups: Groups to test.
    ///   - days: Minimum age in days; a non-positive value matches nothing.
    ///   - now: Reference time for the age cutoff; defaults to the current date.
    /// - Returns: Eligible groups in their original order.
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
