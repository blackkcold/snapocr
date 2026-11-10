import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// Shared inspector for a capture's presentation style. The raw image is never
/// mutated; every change re-renders a preview and the final export on demand.
@MainActor
final class MockupInspectorModel: ObservableObject {
    let rawImage: CGImage
    @Published var style: MockupStyle
    @Published var preview: NSImage?
    @Published var isRendering = false
    @Published var message: String?

    var onStyleChanged: ((MockupStyle) -> Void)?
    var onEdit: ((MockupStyle) -> Void)?
    var onClose: (() -> Void)?

    private var renderTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var lastCommittedStyle: MockupStyle?

    init(
        rawImage: CGImage,
        style: MockupStyle
    ) {
        self.rawImage = rawImage
        self.style = style
        self.lastCommittedStyle = style
        schedulePreview()
    }

    func update(_ mutate: (inout MockupStyle) -> Void) {
        mutate(&style)
        schedulePreview()
    }

    func apply(_ preset: MockupPreset) {
        style = preset.style
        schedulePreview()
    }

    func commitStyle() {
        guard style != lastCommittedStyle else { return }
        lastCommittedStyle = style
        onStyleChanged?(style)
    }

    func schedulePreview() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            await self.renderPreview()
        }
    }

    private func renderPreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        let raw = rawImage
        let style = style
        isRendering = true
        let rendered = await Task.detached(priority: .userInitiated) {
            let previewSource = MockupInspectorModel.downscaled(raw, maximumEdge: 1024)
            return MockupRenderer.render(previewSource, style: style)
        }.value
        guard generation == previewGeneration else { return }
        isRendering = false
        if let rendered {
            preview = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
        }
    }

    func copy() {
        commitStyle()
        let raw = rawImage
        let style = style
        Task {
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                MockupRenderer.render(raw, style: style)
            }).value else { return }
            let nsImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.writeObjects([nsImage]) {
                message = AppLocalization.string("Copied to clipboard")
            } else {
                message = AppLocalization.string("Unable to copy image")
            }
        }
    }

    func save() {
        commitStyle()
        let raw = rawImage
        let style = style
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Snapshot-mockup.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let image = await Task.detached(priority: .userInitiated, operation: {
                MockupRenderer.render(raw, style: style)
            }).value
            guard let image else { return }
            do {
                try await Task.detached {
                    try ImageEncoder.write(image, to: url, format: .png)
                }.value
                message = AppLocalization.string("Saved to %@", url.lastPathComponent)
            } catch {
                message = AppLocalization.string("Save failed: %@", error.localizedDescription)
            }
        }
    }

    func edit() {
        commitStyle()
        onEdit?(style)
    }

    nonisolated private static func downscaled(_ image: CGImage, maximumEdge: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maximumEdge else { return image }
        let scale = CGFloat(maximumEdge) / CGFloat(longEdge)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

struct MockupInspectorView: View {
    @ObservedObject var model: MockupInspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Beautify")
                    .font(.headline)
                Spacer()
                Button {
                    model.onClose?()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("Close"))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                }
                if model.isRendering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 220)

            HStack(spacing: 8) {
                ForEach(MockupPreset.allCases, id: \.self) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(backgroundStyle(preset.style.background))
                            .frame(width: 54, height: 34)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        model.style == preset.style
                                            ? Color.accentColor
                                            : Color.primary.opacity(0.12),
                                        lineWidth: model.style == preset.style ? 2 : 0.5
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .help(Text(LocalizedStringKey(preset.localizedKey)))
                    .accessibilityLabel(Text(LocalizedStringKey(preset.localizedKey)))
                }
            }

            slider(
                "Padding",
                value: Binding(
                    get: { model.style.paddingRatio },
                    set: { value in model.update { $0.paddingRatio = value } }
                ),
                range: 0...0.16
            )
            slider(
                "Corner radius",
                value: Binding(
                    get: { model.style.cornerRadiusRatio },
                    set: { value in model.update { $0.cornerRadiusRatio = value } }
                ),
                range: 0...0.03
            )
            slider(
                "Shadow",
                value: Binding(
                    get: { model.style.shadowOpacity },
                    set: { value in model.update { $0.shadowOpacity = value } }
                ),
                range: 0...0.6
            )

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Copy") { model.copy() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                Button("Save…") { model.save() }
                Button("Edit") { model.edit() }
                Spacer()
                Button("Reset") { model.apply(.light) }
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func slider(
        _ title: LocalizedStringKey,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func backgroundStyle(_ background: MockupStyle.Background) -> AnyShapeStyle {
        switch background {
        case .transparent:
            return AnyShapeStyle(Color.clear)
        case .solid(let red, let green, let blue):
            return AnyShapeStyle(Color(red: red, green: green, blue: blue))
        case .linear(let stops, let angle):
            let colors = stops.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
            return AnyShapeStyle(
                LinearGradient(
                    colors: colors,
                    startPoint: angle >= 90 ? .bottomLeading : .topLeading,
                    endPoint: angle >= 90 ? .topTrailing : .bottomTrailing
                )
            )
        }
    }
}

@MainActor
final class MockupInspectorPanel: NSPanel {
    private static var retainedPanels: [MockupInspectorPanel] = []
    private let model: MockupInspectorModel

    static func show(
        rawImage: CGImage,
        style: MockupStyle,
        onStyleChanged: @escaping (MockupStyle) -> Void,
        onEdit: @escaping (MockupStyle) -> Void
    ) {
        let model = MockupInspectorModel(rawImage: rawImage, style: style)
        let panel = MockupInspectorPanel(model: model)
        model.onStyleChanged = onStyleChanged
        model.onEdit = { [weak panel] style in
            onEdit(style)
            panel?.close()
        }
        // `close()` commits the style; keeping this closure free of `model`
        // breaks the panel → model → closure → panel retain cycle.
        model.onClose = { [weak panel] in
            panel?.close()
        }
        retainedPanels.append(panel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private init(model: MockupInspectorModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 552, height: 590),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: MockupInspectorView(model: model))
    }

    override func close() {
        model.commitStyle()
        super.close()
        Self.retainedPanels.removeAll { $0 === self }
    }
}
