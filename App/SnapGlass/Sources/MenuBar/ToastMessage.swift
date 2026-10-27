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


/// 1 秒内同文案只展示一次。
///
/// 使用引用类型，视图重建不会丢掉「刚弹过」的状态；三个宿主
/// （截图、编辑器、历史）各自持有一个，互不干扰。
@MainActor
final class ToastDeduplicator {
    private var lastMessage: String?
    private var lastTime: TimeInterval = 0

    func shouldPresent(
        _ message: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        if message == lastMessage, now - lastTime < 1.0 {
            return false
        }
        lastMessage = message
        lastTime = now
        return true
    }
}
