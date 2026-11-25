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

    public var id: String { rawValue }
}

public enum LibrarySort: String, CaseIterable, Sendable, Hashable, Identifiable {
    case newest
    case oldest
    case longest
    case largest
    case name

    public var id: String { rawValue }
}

public enum LibraryDateRange: String, CaseIterable, Sendable, Hashable, Identifiable {
    case any
    case today
    case last7Days
    case last30Days
    case custom

    public var id: String { rawValue }
}

public enum LibraryDurationFilter: String, CaseIterable, Sendable, Hashable, Identifiable {
    case any
    case underOneMinute
    case oneToTenMinutes
    case tenToSixtyMinutes
    case overOneHour

    public var id: String { rawValue }
}

public enum LibraryStatusFilter: String, CaseIterable, Sendable, Hashable, Identifiable {
    case any
    case complete
    case partial
    case offline

    public var id: String { rawValue }
}

/// Pure, UI-independent filter state. The App layer maps this to controls and
/// applies it to its presentation rows.
public struct LibraryFilter: Sendable, Equatable {
    public var dateRange: LibraryDateRange
    public var customStart: Date?
    public var customEnd: Date?
    public var duration: LibraryDurationFilter
    public var status: LibraryStatusFilter
    public var favouritesOnly: Bool
    public var location: String?

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

    public var isActive: Bool {
        dateRange != .any
            || duration != .any
            || status != .any
            || favouritesOnly
            || location != nil
    }

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

        switch dateRange {
        case .any:
            break
        case .today:
            guard calendar.isDate(date, inSameDayAs: now) else { return false }
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now), date >= start else {
                return false
            }
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now), date >= start else {
                return false
            }
        case .custom:
            if let customStart, date < customStart { return false }
            if let customEnd, date > customEnd { return false }
        }

        switch duration {
        case .any:
            break
        case .underOneMinute:
            guard seconds < 60 else { return false }
        case .oneToTenMinutes:
            guard seconds >= 60, seconds <= 600 else { return false }
        case .tenToSixtyMinutes:
            guard seconds > 600, seconds <= 3_600 else { return false }
        case .overOneHour:
            guard seconds > 3_600 else { return false }
        }

        if status != .any, itemStatus != status { return false }
        return true
    }
}
