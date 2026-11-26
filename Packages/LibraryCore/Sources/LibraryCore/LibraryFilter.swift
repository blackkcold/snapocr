import Foundation

/// Top-level destinations in the unified library.
public enum LibrarySection: String, CaseIterable, Sendable, Hashable, Identifiable {
    case all
    case favourites
    case screenshots
    case audio
    case video
    case colors
    case recoverable
    case recentlyDeleted

    /// Identifier of the section, equal to its raw value.
    public var id: String { rawValue }
}

/// Order in which the library presents items.
public enum LibrarySort: String, CaseIterable, Sendable, Hashable, Identifiable {
    case newest
    case oldest
    case longest
    case largest
    case name

    /// Identifier of the sort order, equal to its raw value.
    public var id: String { rawValue }
}

/// Date range the library is limited to.
public enum LibraryDateRange: String, CaseIterable, Sendable, Hashable, Identifiable {
    case any
    case today
    case last7Days
    case last30Days
    case custom

    /// Identifier of the range, equal to its raw value.
    public var id: String { rawValue }
}

/// Duration range the library is limited to.
public enum LibraryDurationFilter: String, CaseIterable, Sendable, Hashable, Identifiable {
    case any
    case underOneMinute
    case oneToTenMinutes
    case tenToSixtyMinutes
    case overOneHour

    /// Identifier of the filter, equal to its raw value.
    public var id: String { rawValue }
}

/// Publication status the library is limited to.
public enum LibraryStatusFilter: String, CaseIterable, Sendable, Hashable, Identifiable {
    case any
    case complete
    case partial
    case offline

    /// Identifier of the filter, equal to its raw value.
    public var id: String { rawValue }
}

/// Pure, UI-independent filter state. The App layer maps this to controls and
/// applies it to its presentation rows.
public struct LibraryFilter: Sendable, Equatable {
    /// Date range applied to item dates.
    public var dateRange: LibraryDateRange
    /// Lower bound used when `dateRange` is `.custom`.
    public var customStart: Date?
    /// Upper bound used when `dateRange` is `.custom`.
    public var customEnd: Date?
    /// Duration range applied to recordings.
    public var duration: LibraryDurationFilter
    /// Publication status applied to recordings.
    public var status: LibraryStatusFilter
    /// Whether only favourites pass the filter.
    public var favouritesOnly: Bool
    /// Exact location path an item must have, or `nil` to accept any location.
    public var location: String?

    /// Creates a filter with the given values.
    ///
    /// - Parameters:
    ///   - dateRange: Date range to apply; defaults to `.any`.
    ///   - customStart: Lower bound for `.custom`, if any.
    ///   - customEnd: Upper bound for `.custom`, if any.
    ///   - duration: Duration range to apply; defaults to `.any`.
    ///   - status: Publication status to apply; defaults to `.any`.
    ///   - favouritesOnly: Whether to keep only favourites.
    ///   - location: Exact location path to require, if any.
    public init(
        dateRange: LibraryDateRange = .any,
        customStart: Date? = nil,
        customEnd: Date? = nil,
        duration: LibraryDurationFilter = .any,
        status: LibraryStatusFilter = .any,
        favouritesOnly: Bool = false,
        location: String? = nil
    ) {
        self.dateRange = dateRange
        self.customStart = customStart
        self.customEnd = customEnd
        self.duration = duration
        self.status = status
        self.favouritesOnly = favouritesOnly
        self.location = location
    }

    /// Whether any criterion narrows the library.
    public var isActive: Bool {
        dateRange != .any
            || duration != .any
            || status != .any
            || favouritesOnly
            || location != nil
    }

    /// Returns whether an item passes every criterion of the filter.
    ///
    /// The location criterion compares paths exactly, and relative date ranges
    /// are resolved against `now`.
    ///
    /// - Parameters:
    ///   - date: Capture or start date of the item.
    ///   - seconds: Duration of the item in seconds.
    ///   - itemStatus: Publication status of the item.
    ///   - isFavourite: Whether the user marked the item as a favourite.
    ///   - locationPath: Location path of the item, if it has one.
    ///   - now: Reference time for relative ranges; defaults to the current date.
    ///   - calendar: Calendar used for day and offset arithmetic.
    /// - Returns: `true` if the item passes every criterion.
    public func matches(
        date: Date,
        duration seconds: TimeInterval,
        status itemStatus: LibraryStatusFilter,
        isFavourite: Bool,
        locationPath: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        if favouritesOnly, !isFavourite { return false }
        if let location, location != locationPath { return false }
        guard matchesDate(date, now: now, calendar: calendar) else { return false }
        guard matchesDuration(seconds) else { return false }
        if status != .any, itemStatus != status { return false }
        return true
    }

    private func matchesDate(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        switch dateRange {
        case .any:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return false }
            return date >= start
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return false }
            return date >= start
        case .custom:
            if let customStart, date < customStart { return false }
            if let customEnd, date > customEnd { return false }
            return true
        }
    }

    private func matchesDuration(_ seconds: TimeInterval) -> Bool {
        switch duration {
        case .any:
            return true
        case .underOneMinute:
            return seconds < 60
        case .oneToTenMinutes:
            return seconds >= 60 && seconds <= 600
        case .tenToSixtyMinutes:
            return seconds > 600 && seconds <= 3_600
        case .overOneHour:
            return seconds > 3_600
        }
    }
}
