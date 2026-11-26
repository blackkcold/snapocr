import LibraryCore
import SwiftUI

// MARK: - Content

struct LibraryContent: View {
    @ObservedObject var viewModel: LibraryViewModel
    let captureViewModel: CaptureViewModel
    let isInspectorSheetPresented: Bool
    @FocusState private var isGridFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch viewModel.section {
                case .colors:
                    LibraryColorsView(viewModel: viewModel)
                case .recoverable:
                    LibraryRecoverableView(viewModel: viewModel)
                case .recentlyDeleted:
                    LibraryTrashView(viewModel: viewModel)
                default:
                    mediaContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.isSelecting || !viewModel.selection.isEmpty {
                LibraryBatchBar(viewModel: viewModel)
                    .padding(.horizontal, DS.Space.s12)
                    .padding(.bottom, DS.Space.s12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var mediaContent: some View {
        Group {
            if viewModel.isLoading, viewModel.allItems.isEmpty {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.allItems.isEmpty {
                LibraryEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Library unavailable",
                    message: LocalizedStringKey(error),
                    primaryTitle: "Retry",
                    primaryAction: { Task { await viewModel.refresh() } },
                    secondaryTitle: nil,
                    secondaryAction: nil
                )
            } else if viewModel.filteredItems.isEmpty {
                emptyState
            } else if viewModel.viewMode == .list {
                LibraryListView(
                    viewModel: viewModel,
                    captureViewModel: captureViewModel,
                    gridFocus: $isGridFocused
                )
            } else {
                LibraryGridView(
                    viewModel: viewModel,
                    captureViewModel: captureViewModel,
                    gridFocus: $isGridFocused
                )
            }
        }
        .background { commandShortcuts }
        .onChange(of: viewModel.selectedItemID) { selected in
            // Keyboard commands follow the row the user just clicked, but the
            // grid only takes focus on an explicit selection: the search field
            // keeps the keyboard until then.
            if selected != nil {
                isGridFocused = true
            }
        }
    }

    // MARK: - Keyboard commands

    private var commandContext: LibraryCommandContext {
        let hasSelection = viewModel.selectedItem != nil
        return LibraryCommandContext(
            hasSelection: hasSelection,
            visibleItemCount: viewModel.filteredItems.count,
            canOpen: hasSelection,
            canExport: hasSelection || !viewModel.selection.isEmpty,
            canDelete: hasSelection,
            canFavourite: hasSelection,
            isSelecting: viewModel.isSelecting,
            isSheetPresented: isInspectorSheetPresented
                || viewModel.isShowingDeleteSheet
                || viewModel.isShowingExportSheet
                || viewModel.isShowingMergeSheet
                || viewModel.isShowingRecoverableSheet
                || viewModel.isShowingStorageSheet
        )
    }

    /// Shortcut bindings come from `LibraryCommand` so the table the tests
    /// exercise is the one the window actually uses. They stay disabled until
    /// the grid has focus, which keeps ⌘A, space and escape out of the search
    /// field and the inspector's text fields.
    private var commandShortcuts: some View {
        ForEach(LibraryCommand.allCases, id: \.self) { command in
            Button(AppLocalization.string(command.titleKey)) {
                perform(command)
            }
            .keyboardShortcut(
                keyEquivalent(for: command),
                modifiers: eventModifiers(for: command)
            )
            .disabled(
                !isGridFocused
                    || !LibraryCommandRouter.isEnabled(command, context: commandContext)
            )
            .hidden()
        }
    }

    private func perform(_ command: LibraryCommand) {
        guard LibraryCommandRouter.isEnabled(command, context: commandContext) else { return }
        switch command {
        case .preview:
            quickLookSelected()
        case .open:
            openSelectedItem()
        case .export:
            if !viewModel.isSelecting || viewModel.selection.isEmpty {
                guard let id = viewModel.selectedItemID else { return }
                viewModel.selection = [id]
                viewModel.isSelecting = true
            }
            viewModel.isShowingExportSheet = true
        case .delete:
            viewModel.requestDeleteSelection()
        case .favourite:
            guard let item = viewModel.selectedItem else { return }
            Task { await viewModel.toggleFavourite(item) }
        case .selectAll:
            viewModel.selectAllVisible()
        case .cancel:
            viewModel.cancelSelection()
        }
    }

    private func keyEquivalent(for command: LibraryCommand) -> KeyEquivalent {
        switch command {
        case .preview: return " "
        case .open: return .return
        case .export: return "e"
        case .delete: return .delete
        case .favourite: return "f"
        case .selectAll: return "a"
        case .cancel: return .escape
        }
    }

    private func eventModifiers(for command: LibraryCommand) -> EventModifiers {
        var result: EventModifiers = []
        for modifier in command.modifiers {
            switch modifier {
            case .command: result.insert(.command)
            case .shift: result.insert(.shift)
            case .option: result.insert(.option)
            case .control: result.insert(.control)
            }
        }
        return result
    }

    private func openSelectedItem() {
        guard let item = viewModel.selectedItem else { return }
        switch item {
        case .screenshot(let entry):
            Task { await viewModel.openScreenshot(entry, using: captureViewModel) }
        case .recording(let group):
            viewModel.openRecording(group)
        }
    }

    private func quickLookSelected() {
        guard let item = viewModel.selectedItem else { return }
        Task {
            let urls = await viewModel.quickLookURLs(for: item)
            guard !urls.isEmpty else {
                viewModel.showToast(
                    AppLocalization.string("Preview unavailable"),
                    type: .error
                )
                return
            }
            LibraryQuickLookCoordinator.shared.show(urls)
        }
    }

    private var emptyState: some View {
        let searching = !viewModel.searchText.isEmpty || viewModel.filter.isActive
        if searching {
            return LibraryEmptyState(
                icon: "magnifyingglass",
                title: "No results",
                message: "Try a different search or clear the filters.",
                primaryTitle: "Clear search",
                primaryAction: {
                    viewModel.searchText = ""
                    viewModel.filter = LibraryFilter()
                },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        }
        switch viewModel.section {
        case .audio:
            return LibraryEmptyState(
                icon: "waveform",
                title: "No audio recordings",
                message: "Audio recordings appear here as soon as they finish.",
                primaryTitle: "Record audio",
                primaryAction: { Task { await captureViewModel.startDefaultAudioRecording() } },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        case .video:
            return LibraryEmptyState(
                icon: "rectangle.dashed.badge.record",
                title: "No video recordings",
                message: "Screen recordings appear here when they are published.",
                primaryTitle: "Record screen",
                primaryAction: { captureViewModel.startRecording() },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        case .favourites:
            return LibraryEmptyState(
                icon: "star",
                title: "No favourites yet",
                message: "Star a screenshot, audio or video to keep it here.",
                primaryTitle: "Show all",
                primaryAction: { viewModel.selectSection(.all) },
                secondaryTitle: nil,
                secondaryAction: nil
            )
        default:
            return LibraryEmptyState(
                icon: "clock.arrow.circlepath",
                title: "No history yet",
                message: "Screenshots, audio and video will appear here.",
                primaryTitle: "Record audio",
                primaryAction: { Task { await captureViewModel.startDefaultAudioRecording() } },
                secondaryTitle: "Record screen",
                secondaryAction: { captureViewModel.startRecording() }
            )
        }
    }
}
