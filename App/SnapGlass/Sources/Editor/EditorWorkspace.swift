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
    public struct Tab: Identifiable {
        public let id: UUID
        public let viewModel: EditorViewModel
        public var context: EditorCaptureContext
        public let title: String
    }

    /// 5K 底图单张约 59MB。未做冷存储前把并发标签压到 4 个，
    /// 避免用户一次拖入十几张截图后常驻内存失控。
    public static let maxTabs = 4

    @Published public private(set) var tabs: [Tab] = []
    @Published public private(set) var activeTabID: UUID?
    @Published public private(set) var pendingCloseIDs: Set<UUID> = []

    public var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    public var dirtyTabs: [Tab] { tabs.filter { isDirty($0) } }

    /// 标签的脏状态；放在 workspace 上以避免嵌套类型跨 actor 访问。
    public func isDirty(_ tab: Tab) -> Bool {
        tab.viewModel.hasUnsavedChanges && !tab.viewModel.hasAcceptedClose
    }
    public var hasAnyUnsavedChanges: Bool { !dirtyTabs.isEmpty }
    public var showsCloseConfirmation: Bool { !pendingCloseIDs.isEmpty }
    public var pendingTabs: [Tab] { tabs.filter { pendingCloseIDs.contains($0.id) } }

    /// 由窗口宿主注入，避免工作区直接依赖 App 层窗口定位。
    public var closeWindowAction: () -> Void = {}

    private var nextTitleIndex = 1

    public init() {}

    /// 打开一张新截图。返回 `nil` 表示已达标签上限。
    @discardableResult
    public func open(image: CGImage, context: EditorCaptureContext) -> Tab? {
        if let entryID = context.sourceEntryID,
            let existing = tabs.first(where: { $0.context.sourceEntryID == entryID }) {
            activeTabID = existing.id
            return existing
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

    public func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    public func requestClose(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if isDirty(tab) {
            pendingCloseIDs = [id]
        } else {
            close(id)
        }
    }

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

    public func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
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

    public func discardPendingAndClose() {
        let ids = pendingCloseIDs
        pendingCloseIDs.removeAll()
        for id in ids {
            close(id)
        }
    }

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
        closeWindowAction()
    }

    private func nextTitle() -> String {
        defer { nextTitleIndex += 1 }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(nextTitleIndex) · \(formatter.string(from: Date()))"
    }
}
