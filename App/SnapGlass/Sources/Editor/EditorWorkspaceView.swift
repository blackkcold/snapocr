import SwiftUI

/// 编辑器窗口的内容宿主：标签条 + 当前标签的画布。
///
/// 窗口级关窗守卫装在这里，而不是每个标签的 `EditorView` 里——否则
/// 多标签时只有当前标签参与脏检查，其余标签会被静默丢弃。
struct EditorWorkspaceView: View {
    @ObservedObject var workspace: EditorWorkspace

    var body: some View {
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 {
                tabStrip
            }
            if let tab = workspace.activeTab {
                EditorView(viewModel: tab.viewModel, context: tab.context)
                    .id(tab.id)
                    .onAppear {
                        tab.viewModel.onClose = { workspace.requestClose(tab.id) }
                        tab.viewModel.onForceClose = { workspace.requestClose(tab.id) }
                    }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(
            EditorWindowCloseGuard(
                isDirty: { workspace.hasAnyUnsavedChanges },
                onBlocked: { workspace.requestCloseWindow() }
            )
        )
        .onAppear {
            workspace.closeWindowAction = {
                AppWindowPresenter.window(id: "editor")?.close()
            }
        }
        .sheet(isPresented: closeSheetBinding) {
            closeConfirmation
        }
    }

    private var closeSheetBinding: Binding<Bool> {
        Binding(
            get: { workspace.showsCloseConfirmation },
            set: { presented in
                if !presented { workspace.cancelPendingClose() }
            }
        )
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabButton(_ tab: EditorWorkspace.Tab) -> some View {
        let isActive = tab.id == workspace.activeTabID
        return HStack(spacing: 6) {
            if workspace.isDirty(tab) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(verbatim: tab.title)
                .font(.caption)
                .lineLimit(1)
            Button {
                workspace.requestClose(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            .modifier(TabCloseShortcut(isEnabled: isActive && workspace.tabs.count > 1))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { workspace.activate(tab.id) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No open screenshots")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closeConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save your annotations?")
                .font(.headline)

            Text(verbatim: pendingDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Discard", role: .destructive) {
                    workspace.discardPendingAndClose()
                }
                Spacer()
                Button("Cancel") {
                    workspace.cancelPendingClose()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save to History") {
                    Task { await workspace.savePendingAndClose() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled()
    }

    private var pendingDescription: String {
        let count = workspace.pendingTabs.count
        guard count > 1 else {
            return AppLocalization.string(
                "Closing the editor now discards the annotations on this screenshot.")
        }
        return AppLocalization.string("Discard annotations in %lld tabs?", count)
    }
}

/// 只有多标签时才把 ⌘W 绑到「关标签」；单标签仍交给系统关窗。
private struct TabCloseShortcut: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.keyboardShortcut("w", modifiers: .command)
        } else {
            content
        }
    }
}
