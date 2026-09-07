import Foundation

/// Represents a toast message without coupling consumers to capture services.
public struct ToastMessage: Equatable {
  /// Stable identity for presentation and dismissal.
  public let id: UUID
  /// The message text.
  public let message: String
  /// The type of toast.
  public let type: ToastType
  /// Optional title for a user action.
  public let actionLabel: String?
  let action: (@MainActor () -> Void)?

  init(
    id: UUID = UUID(), message: String, type: ToastType,
    actionLabel: String? = nil, action: (@MainActor () -> Void)? = nil
  ) {
    self.id = id
    self.message = message
    self.type = type
    self.actionLabel = actionLabel
    self.action = action
  }

  /// Messages compare by their stable presentation identity.
  public static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

/// The type of toast notification.
public enum ToastType {
  /// A success notification.
  case success
  /// An error notification.
  case error
  /// An informational notification.
  case info
}
