import AppKit
import CaptureCore
import HistoryCore
import LibraryCore
import SwiftUI

// MARK: - Root

struct LibraryView: View {
    @EnvironmentObject private var captureViewModel: CaptureViewModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var viewModel = LibraryViewModel()
    @StateObject private var rootWatcher = LibraryRootWatcher()
    @ObservedObject private var deepLink = LibraryDeepLink.shared
    @State private var showInspectorSheet = false

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 1_000
            HStack(alignment: .top, spacing: DS.Space.s10) {
                LibrarySidebar(viewModel: viewModel)

                VStack(spacing: 0) {
                    LibraryHeader(
                        viewModel: viewModel,
                        isWide: isWide,
                        openInspector: {
                            if isWide {
                                viewModel.isInspectorPresented.toggle()
                            } else {
                                showInspectorSheet = true
                            }
                        }
                    )
                    Divider().opacity(0.55)
                    if captureViewModel.recordingStatus != .idle {
                        LibraryLiveRecordingBanner(captureViewModel: captureViewModel)
                    }
                    if !viewModel.offlineRoots.isEmpty {
                        HStack(spacing: DS.Space.s8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(
                                AppLocalization.string(
                                    "%@ recording folder(s) offline",
                                    String(viewModel.offlineRoots.count)
                                )
                            )
                            .font(DS.Typography.caption)
                            Spacer()
                            Button("Retry") {
                                Task { await viewModel.refresh() }
                            }
                            .frame(minHeight: 24)
                        }
                        .padding(.horizontal, DS.Space.s12)
                        .padding(.vertical, DS.Space.s6)
                        .background(
                            Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .padding(.horizontal, DS.Space.s12)
                        .padding(.bottom, DS.Space.s6)
                        .help(viewModel.offlineRoots.joined(separator: "\n"))
                    }
                    LibraryContent(
                        viewModel: viewModel,
                        captureViewModel: captureViewModel,
                        isInspectorSheetPresented: showInspectorSheet
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isWide, viewModel.isInspectorPresented, let item = viewModel.selectedItem {
                    LibraryInspector(
                        viewModel: viewModel,
                        item: item,
                        captureViewModel: captureViewModel
                    )
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(DS.Space.s12)
            .frame(minWidth: 720, minHeight: 520)
            .background {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
            }
            .animation(.easeInOut(duration: DS.Motion.base), value: viewModel.isInspectorPresented)
            .sheet(isPresented: $showInspectorSheet) {
                if let item = viewModel.selectedItem {
                    LibraryInspector(
                        viewModel: viewModel,
                        item: item,
                        captureViewModel: captureViewModel
                    )
                    .frame(minWidth: 420, minHeight: 520)
                }
            }
            .sheet(isPresented: $viewModel.isShowingDeleteSheet) {
                LibraryDeleteSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingExportSheet) {
                LibraryExportSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingMergeSheet) {
                LibraryMergeSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingRecoverableSheet) {
                LibraryRecoverableSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isShowingStorageSheet) {
                LibraryStorageSheet(viewModel: viewModel)
            }
        }
        .task { await viewModel.load() }
        .onAppear {
            rootWatcher.start(
                roots: RecordingExportRoots.current().map(\.root)
            )
        }
        .onDisappear {
            rootWatcher.stop()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .recordingLibraryDidChange)
        ) { _ in
            Task { await viewModel.refresh() }
        }
        .onAppear {
            if let request = deepLink.consume() {
                viewModel.handleDeepLink(request)
            }
        }
        .onChange(of: deepLink.request) { request in
            guard let request else { return }
            _ = deepLink.consume()
            viewModel.handleDeepLink(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryActor.imagesDidChange)) { _ in
            Task { await viewModel.refreshScreenshots() }
        }
        .toast(message: $viewModel.toastMessage, edge: .bottom)
    }
}
