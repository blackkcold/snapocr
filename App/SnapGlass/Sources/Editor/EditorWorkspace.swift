import AppKit
import SwiftUI

/// 一个编辑器窗口内的多标签工作区。
///
/// 不变量：
/// - `open` 永不销毁已有标签；同一历史条目重复打开只激活原标签。
/// - 每个标签的脏状态只由自己的 `EditorViewModel` 决定。
/// - 关窗/关标签统一经过这里，禁止单个 ViewModel 自行关窗。
@MainActor
public final class EditorWorkspace: ObservableObject {
    /// One open image and the editor state that owns it.
    public struct Tab: Identifiable {
        /// Stable identity used for selection and close tracking.
        public let id: UUID
        /// The document, tools, and saved state for this tab.
        public let viewModel: EditorViewModel
        /// Capture identity; kept current when the history write finishes or the style changes.
        public var context: EditorCaptureContext
        /// Tab-strip label assigned when the tab opens.
        public let title: String
    }

    /// 5K 底图单张约 59MB。未做冷存储前把并发标签压到 4 个，
    /// 避免用户一次拖入十几张截图后常驻内存失控。
    public static let maxTabs = 4

    /// Open tabs in the order they were added.
    @Published public private(set) var tabs: [Tab] = []
    /// Identifier of the tab shown in the editor, or `nil` when no tab is open.
    @Published public private(set) var activeTabID: UUID?
    /// Tabs waiting for the user to confirm discarding unsaved changes.
    @Published public private(set) var pendingCloseIDs: Set<UUID> = []

    /// The tab currently shown, if any.
    public var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    /// Tabs whose edits have not been saved to history.
    public var dirtyTabs: [Tab] { tabs.filter { isDirty($0) } }

    /// 标签的脏状态；放在 workspace 上以避免嵌套类型跨 actor 访问。
    public func isDirty(_ tab: Tab) -> Bool {
        tab.viewModel.hasUnsavedChanges && !tab.viewModel.hasAcceptedClose
    }
    /// Whether closing the window now would discard edits from any tab.
    public var hasAnyUnsavedChanges: Bool { !dirtyTabs.isEmpty }
    /// Whether the close confirmation sheet should be presented.
    public var showsCloseConfirmation: Bool { !pendingCloseIDs.isEmpty }
    /// Tabs awaiting close confirmation, in tab order.
    public var pendingTabs: [Tab] { tabs.filter { pendingCloseIDs.contains($0.id) } }

    /// 由窗口宿主注入，避免工作区直接依赖 App 层窗口定位。
    public var closeWindowAction: () -> Void = {}

    /// 编辑器窗口真正关闭后回调；用于解除截图架等窗口级抑制。
    public var onWindowClosed: (() -> Void)?

    /// 关闭最后一个标签或用户关窗时都会走到窗口的 `windowWillClose`，
    /// 由窗口宿主转发到这里。
    public func windowDidClose() {
        onWindowClosed?()
    }

    private var nextTitleIndex = 1

    /// Creates an empty workspace with no tabs.
    public init() {}

    /// 打开一张新截图。返回 `nil` 表示已达标签上限。
    @discardableResult
    public func open(image: CGImage, context: EditorCaptureContext) -> Tab? {
        if let entryID = context.sourceEntryID,
            let index = tabs.firstIndex(where: { $0.context.sourceEntryID == entryID })
        {
            // Reusing the tab must still adopt the latest presentation style;
            // otherwise an inspector change made after the tab opened would be
            // overwritten with the stale style on "Overwrite Original".
            tabs[index].context.mockupStyle = context.mockupStyle
            tabs[index].viewModel.adoptMockupStyle(context.mockupStyle)
            activeTabID = tabs[index].id
            return tabs[index]
        }
        guard tabs.count < Self.maxTabs else { return nil }
        let tab = Tab(
            id: UUID(),
            viewModel: EditorViewModel(image: image, context: context),
            context: context,
            title: nextTitle()
        )
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    /// Makes an open tab active; unknown identifiers are ignored.
    public func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    /// Closes a clean tab, or asks for confirmation when it has unsaved changes.
    public func requestClose(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if isDirty(tab) {
            pendingCloseIDs = [id]
        } else {
            close(id)
        }
    }

    /// Requests close for the active tab, if there is one.
    public func requestCloseActiveTab() {
        guard let activeTabID else { return }
        requestClose(activeTabID)
    }

    /// 窗口关闭（红灯、⌘W、⌘Q）统一走这里。
    public func requestCloseWindow() {
        let dirty = Set(dirtyTabs.map(\.id))
        if dirty.isEmpty {
            closeWindow()
        } else {
            pendingCloseIDs = dirty
        }
    }

    /// Removes a tab and closes the window when it was the last one.
    ///
    /// Pending style metadata is flushed first. The neighbouring tab on the
    /// right, or the last remaining tab, becomes active when the closed tab was
    /// the active one.
    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].viewModel.flushShareStyleCommit()
        tabs.remove(at: index)
        pendingCloseIDs.remove(id)
        if tabs.isEmpty {
            activeTabID = nil
            closeWindow()
            return
        }
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// 保存所有未保存标签到历史但不关闭它们。任一保存失败返回 `false`。
    @discardableResult
    public func saveAllDirtyToHistory() async -> Bool {
        for tab in dirtyTabs {
            let mode: EditorHistorySaveMode =
                tab.viewModel.canOverwriteOriginal ? .overwriteOriginal : .newRecord
            await tab.viewModel.saveToHistory(mode: mode)
            if tab.viewModel.hasUnsavedChanges { return false }
        }
        return true
    }

    /// 保存所有待关闭标签到历史，然后关闭。保存失败时保留确认框。
    public func savePendingAndClose() async {
        for tab in pendingTabs {
            let mode: EditorHistorySaveMode =
                tab.viewModel.canOverwriteOriginal ? .overwriteOriginal : .newRecord
            await tab.viewModel.saveToHistory(mode: mode)
            guard !tab.viewModel.hasUnsavedChanges else { return }
            close(tab.id)
        }
        pendingCloseIDs.removeAll()
    }

    /// Closes every tab awaiting confirmation without saving its changes.
    public func discardPendingAndClose() {
        let ids = pendingCloseIDs
        pendingCloseIDs.removeAll()
        for id in ids {
            close(id)
        }
    }

    /// Dismisses the close confirmation and keeps all pending tabs open.
    public func cancelPendingClose() {
        pendingCloseIDs.removeAll()
    }

    /// 后台历史写入完成后把记录 id 补到对应标签，保留「覆盖原记录」。
    public func attachSourceEntry(_ entryID: UUID, to tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].context.sourceEntryID = entryID
        tabs[index].viewModel.attachSourceEntry(entryID)
    }

    private func closeWindow() {
        for tab in tabs {
            tab.viewModel.flushShareStyleCommit()
        }
        closeWindowAction()
    }

    private func nextTitle() -> String {
        defer { nextTitleIndex += 1 }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(nextTitleIndex) · \(formatter.string(from: Date()))"
    }
}
