import AppKit
import SharedKit
import SwiftUI

/// Full-size preview of the current share appearance.
///
/// Shows the same downscaled composite as the inspector, on a checkerboard so
/// transparent backgrounds are visible. Copy and Save act on the full-size
/// render, not on this preview bitmap.
struct ShareAppearancePreviewSheet: View {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s14) {
            HStack {
                Label("Export preview", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            ZStack {
                CheckerboardBackground(square: 10)
                if let preview = viewModel.sharePreview {
                    Image(
                        nsImage: NSImage(
                            cgImage: preview,
                            size: NSSize(width: preview.width, height: preview.height)
                        )
                    )
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(DS.Space.s16)
                } else if viewModel.sharePreviewState == .rendering {
                    ProgressView()
                } else {
                    Text("No preview yet")
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.c10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Corner.c10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }

            HStack(spacing: DS.Space.s8) {
                Text("Transparent areas show as a checkerboard")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Original") {
                    viewModel.copyOriginalToClipboard()
                    dismiss()
                }
                Button("Copy Share Image") {
                    viewModel.copyToClipboard()
                    dismiss()
                }
                .disabled(!viewModel.isShareAppearanceEnabled)
                Button("Save…") {
                    dismiss()
                    viewModel.save()
                }
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.s16)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            viewModel.refreshSharePreviewIfNeeded(force: true)
        }
    }
}
