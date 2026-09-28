import Foundation

/// 悬浮工具条的显隐状态机。
///
/// 纯值类型，不依赖 AppKit，因此可在 `swift test --package-path Packages/CaptureCore` 下直接验证。
/// 工具条与面板是两个独立窗口，鼠标从面板移向工具条必然触发面板的 `mouseExited`，
/// 因此隐藏必须延迟，并由工具条自身的进入事件取消。
public struct PinnedToolbarVisibility: Equatable, Sendable {
    /// 鼠标离开后延迟隐藏的时长（秒）。
    public static let defaultHideDelay: TimeInterval = 0.3

    /// 鼠标进入后延迟显示的时长（秒），避免快速划过时闪烁。
    public static let defaultShowDelay: TimeInterval = 0.15

    /// 工具条当前是否应该可见。
    public private(set) var isVisible: Bool

    private var isPointerInside: Bool
    private var isInteracting: Bool
    private var showDelay: TimeInterval
    private var hideDelay: TimeInterval

    /// 创建一个初始隐藏的状态机。
    ///
    /// - Parameters:
    ///   - showDelay: 进入后延迟显示的时长。
    ///   - hideDelay: 离开后延迟隐藏的时长。
    public init(
        showDelay: TimeInterval = PinnedToolbarVisibility.defaultShowDelay,
        hideDelay: TimeInterval = PinnedToolbarVisibility.defaultHideDelay
    ) {
        self.isVisible = false
        self.isPointerInside = false
        self.isInteracting = false
        self.showDelay = max(0, showDelay)
        self.hideDelay = max(0, hideDelay)
    }

    /// 鼠标进入面板或工具条时应等待的时长。
    ///
    /// - Returns: 延迟秒数；已可见时返回 `0`。
    public var pendingShowDelay: TimeInterval {
        isVisible ? 0 : showDelay
    }

    /// 鼠标离开面板与工具条时应等待的时长。
    ///
    /// 拖动滑杆或缩放进行中不隐藏，因此返回 `nil` 表示「保持现状」。
    ///
    /// - Returns: 延迟秒数；不应隐藏时返回 `nil`。
    public var pendingHideDelay: TimeInterval? {
        guard isPointerInside == false, isInteracting == false else { return nil }
        return isVisible ? hideDelay : nil
    }

    /// 记录鼠标进入面板或工具条。
    public mutating func pointerEntered() {
        isPointerInside = true
    }

    /// 记录鼠标离开面板与工具条。
    public mutating func pointerExited() {
        isPointerInside = false
    }

    /// 记录拖拽/缩放等交互开始，期间禁止隐藏。
    public mutating func interactionBegan() {
        isInteracting = true
    }

    /// 记录交互结束，若鼠标已离开则回到延迟隐藏流程。
    public mutating func interactionEnded() {
        isInteracting = false
    }

    /// 应用延迟计时结束后的结果：显示工具条。
    ///
    /// - Returns: 状态是否实际发生变化。
    @discardableResult
    public mutating func applyShow() -> Bool {
        guard !isVisible else { return false }
        isVisible = true
        return true
    }

    /// 应用延迟计时结束后的结果：隐藏工具条。
    ///
    /// 鼠标仍在面板/工具条内或交互进行中时不会隐藏。
    ///
    /// - Returns: 状态是否实际发生变化。
    @discardableResult
    public mutating func applyHide() -> Bool {
        guard isVisible, !isPointerInside, !isInteracting else { return false }
        isVisible = false
        return true
    }
}
