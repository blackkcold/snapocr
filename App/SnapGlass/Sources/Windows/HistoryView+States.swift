import AppKit
import HistoryCore
import SharedKit
import SwiftUI

// MARK: - HistoryView States

extension HistoryView {
    // MARK: - Loading / Unavailable State

    var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading history…")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var unavailableState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("History unavailable")
                .font(.title3)
                .foregroundColor(.secondary)

            Text(loadError ?? AppLocalization.string("Check the application support folder permissions"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            HStack(spacing: 12) {
                Button("Retry") {
                    Task { await retryHistoryInitialization() }
                }
                Button("Open Storage Folder") {
                    openHistoryFolder()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func openHistoryFolder() {
        let folder = URL.appSupportDirectory
            .appendingPathComponent("History")
            .appendingPathComponent("v2")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// 取色历史存储初始化失败：与「还没有取过色」区分开，并给出重试入口。
    var colorUnavailableState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("History unavailable")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("Check the application support folder permissions")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            HStack(spacing: 12) {
                Button("Retry") {
                    Task { await retryColorHistoryInitialization() }
                }
                Button("Open Storage Folder") {
                    openHistoryFolder()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    var emptyStateTitle: LocalizedStringKey {
        if history == nil {
            return "History unavailable"
        }
        return searchQuery.isEmpty && favouriteFilter == .all ? "No captures yet" : "No results found"
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(emptyStateTitle)
                .font(.title3)
                .foregroundColor(.secondary)

            if history == nil {
                Text("Check the application support folder permissions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if !searchQuery.isEmpty {
                Text("Try a different search term")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var colorEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "paintpalette")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(colorEmptyStateTitle)
                .font(.title3)
                .foregroundColor(.secondary)

            if !colorFilter.isEmpty {
                Text("Try a different search term")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var colorEmptyStateTitle: LocalizedStringKey {
        colorFilter.isEmpty ? "No colors captured yet" : "No matching colors"
    }

}
