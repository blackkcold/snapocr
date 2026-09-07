import Foundation

/// Screenshot filtering and deterministic ordering, independent of the view layer.
public struct HistoryPresentation: Sendable {
  /// The subset of favourite states to display.
  public enum Filter: String, CaseIterable, Sendable {
    case all, favourites, unfavourited
  }

  /// Whether favourites precede or follow other captures.
  public enum FavouriteOrder: String, CaseIterable, Sendable {
    case first, last
  }

  /// Returns favourite groups sorted by timestamp, with stable ID tie-breaking.
  public static func entries(
    _ entries: [HistoryEntry], filter: Filter, favouriteOrder: FavouriteOrder, newestFirst: Bool
  ) -> [HistoryEntry] {
    entries.filter { entry in
      switch filter {
      case .all: true
      case .favourites: entry.isFavourite
      case .unfavourited: !entry.isFavourite
      }
    }.sorted { lhs, rhs in
      if lhs.isFavourite != rhs.isFavourite {
        return favouriteOrder == .first ? lhs.isFavourite : !lhs.isFavourite
      }
      if lhs.timestamp != rhs.timestamp {
        return newestFirst ? lhs.timestamp > rhs.timestamp : lhs.timestamp < rhs.timestamp
      }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// Three to five columns normally, with fewer columns in narrow windows.
  public static func columnCount(for width: Double) -> Int {
    min(5, max(1, Int(max(width, 0) / 180)))
  }
}
