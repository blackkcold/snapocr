import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// The inspector page for the capture's share appearance.
///
/// The page edits `EditorViewModel.mockupStyle` only. The annotation canvas
/// draws that style live through the same `MockupLayout`/`MockupRenderer`
/// pair; the preview card stays for a quick check without leaving the page.
struct ShareAppearanceInspectorView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var showsPreview = false

    private var style: MockupStyle? { viewModel.mockupStyle }
    private var isEnabled: Bool { style != nil }

    private var referenceSide: CGFloat {
        guard let image = viewModel.document?.baseImage else { return 0 }
        return MockupRenderer.referenceSide(
            for: CGSize(width: image.width, height: image.height)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s12) {
            header
            previewCard

            if case .failed(let message) = viewModel.sharePreviewState {
                previewFailure(message)
            }

            controls

            if isEnabled, let note = viewModel.shareAppearanceContextNote {
                Label(note, systemImage: "info.circle")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isEnabled, style?.isTransparent == true {
                Label(
                    "JPEG cannot keep a transparent background; it will be filled with white",
                    systemImage: "exclamationmark.triangle"
                )
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .onAppear {
            viewModel.refreshSharePreviewIfNeeded(force: true)
        }
        .onChange(of: viewModel.changeCount) { _ in
            viewModel.refreshSharePreviewIfNeeded(force: true)
        }
        .sheet(isPresented: $showsPreview) {
            ShareAppearancePreviewSheet(viewModel: viewModel)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s8) {
                Label("Share-ready look", systemImage: "sparkles")
                    .font(DS.Typography.bodyStrong)
                Spacer(minLength: DS.Space.s8)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isEnabled },
                        set: { viewModel.setShareAppearanceEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Share-ready look")
            }
            Text("Add a background, padding, and shadow")
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        Button {
            showsPreview = true
        } label: {
            ZStack {
                CheckerboardBackground(square: 8)
                if let preview = viewModel.sharePreview {
                    Image(nsImage: NSImage(
                        cgImage: preview,
                        size: NSSize(width: preview.width, height: preview.height)
                    ))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(DS.Space.s6)
                } else if viewModel.sharePreviewState == .rendering {
                    ProgressView()
                        .controlSize(.small)
                } else if case .failed = viewModel.sharePreviewState {
                    VStack(spacing: DS.Space.s4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("Unable to render preview")
                            .font(DS.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(spacing: DS.Space.s4) {
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No preview yet")
                            .font(DS.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 128)
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.c8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Corner.c8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Export preview")
        .accessibilityLabel("Export preview")
    }

    private func previewFailure(_ message: String) -> some View {
        HStack(spacing: DS.Space.s6) {
            Text("Unable to render preview")
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(message)
            Spacer(minLength: 0)
            Button("Retry") {
                viewModel.refreshSharePreviewIfNeeded(force: true)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s10) {
            Text("Template")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                spacing: 4
            ) {
                ForEach(MockupPreset.allCases, id: \.self) { preset in
                    PresetSwatch(
                        preset: preset,
                        isSelected: viewModel.selectedMockupPreset == preset
                    ) {
                        viewModel.applyMockupPreset(preset)
                    }
                }
            }

            shareSlider(
                "Padding",
                value: Binding(
                    get: { style?.paddingRatio ?? 0.08 },
                    set: { value in
                        viewModel.updateMockupStyle { $0.paddingRatio = value }
                    }
                ),
                range: 0...0.16,
                step: 0.005,
                valueText: "\(Int(((style?.paddingRatio ?? 0.08) * 100).rounded()))%"
            )

            shareSlider(
                "Corner radius",
                value: Binding(
                    get: { style?.cornerRadiusRatio ?? 0.012 },
                    set: { value in
                        viewModel.updateMockupStyle { $0.cornerRadiusRatio = value }
                    }
                ),
                range: 0...0.03,
                step: 0.002,
                valueText: cornerText
            )

            shareSlider(
                "Shadow",
                value: Binding(
                    get: { style?.shadowOpacity ?? 0.28 },
                    set: { value in
                        viewModel.updateMockupStyle { $0.shadowOpacity = value }
                    }
                ),
                range: 0...0.6,
                step: 0.02,
                valueText: "\(Int(((style?.shadowOpacity ?? 0.28) * 100).rounded()))%"
            )

            borderControls

            borderColorControls
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var borderControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack {
                Text("Border")
                    .font(DS.Typography.caption)
                Spacer()
                Text(borderPixelText)
                    .font(DS.Typography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Picker("Border width", selection: borderLevelBinding) {
                Text("None").tag(0)
                Text("Thin").tag(1)
                Text("Standard").tag(2)
                Text("Thick").tag(3)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var borderColorControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack {
                Text("Border color")
                    .font(DS.Typography.caption)
                Spacer()
                Picker("Border color", selection: borderColorModeBinding) {
                    Text("Automatic").tag(BorderColorMode.automatic)
                    Text("Black").tag(BorderColorMode.black)
                    Text("White").tag(BorderColorMode.white)
                    Text("Custom").tag(BorderColorMode.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Border color")
            }
            if borderColorMode == .custom {
                ColorPicker(
                    "Border color",
                    selection: customBorderColorBinding,
                    supportsOpacity: true
                )
                .labelsHidden()
                .accessibilityLabel("Border color")
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset") {
                viewModel.resetMockupStyle()
            }
            .controlSize(.small)
            .disabled(!isEnabled)

            Spacer()

            Button {
                showsPreview = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Export preview")
            .accessibilityLabel("Export preview")
        }
    }

    // MARK: - Values

    private var cornerText: String {
        guard let image = viewModel.document?.baseImage, let style else { return "—" }
        let layout = MockupLayout.make(
            imageSize: CGSize(width: image.width, height: image.height),
            style: style
        )
        return "≈\(Int(layout.cornerRadius.rounded())) px"
    }

    private var borderPixelText: String {
        guard let image = viewModel.document?.baseImage, let style else { return "—" }
        let layout = MockupLayout.make(
            imageSize: CGSize(width: image.width, height: image.height),
            style: style
        )
        guard layout.borderWidth > 0 else { return "—" }
        return "≈\(Int(layout.borderWidth.rounded())) px"
    }

    private var borderLevel: Int {
        let ratio = style?.borderWidthRatio ?? 0
        guard ratio > 0 else { return 0 }
        if ratio < 0.0009 { return 1 }
        if ratio < 0.0018 { return 2 }
        return 3
    }

    private var borderLevelBinding: Binding<Int> {
        Binding(
            get: { borderLevel },
            set: { level in
                let ratios: [CGFloat] = [0, 0.000625, 0.00125, 0.0025]
                let ratio = ratios[min(max(level, 0), ratios.count - 1)]
                viewModel.updateMockupStyle { $0.borderWidthRatio = ratio }
            }
        )
    }

    private var borderColorMode: BorderColorMode {
        guard let style else { return .automatic }
        switch style.borderColor {
        case .automatic:
            return .automatic
        case .custom(let red, let green, let blue, let alpha):
            if red < 0.05, green < 0.05, blue < 0.05, alpha >= 0.1 { return .black }
            if red > 0.95, green > 0.95, blue > 0.95, alpha >= 0.1 { return .white }
            return .custom
        }
    }

    private var borderColorModeBinding: Binding<BorderColorMode> {
        Binding(
            get: { borderColorMode },
            set: { mode in
                switch mode {
                case .automatic:
                    viewModel.updateMockupStyle { $0.borderColor = .automatic }
                case .black:
                    viewModel.updateMockupStyle {
                        $0.borderColor = .custom(red: 0, green: 0, blue: 0, alpha: 0.18)
                    }
                case .white:
                    viewModel.updateMockupStyle {
                        $0.borderColor = .custom(red: 1, green: 1, blue: 1, alpha: 0.55)
                    }
                case .custom:
                    guard borderColorMode != .custom else { return }
                    viewModel.updateMockupStyle {
                        $0.borderColor = .custom(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)
                    }
                }
            }
        )
    }

    private var customBorderColorBinding: Binding<Color> {
        Binding(
            get: {
                guard case .custom(let red, let green, let blue, let alpha) = style?.borderColor else {
                    return .black
                }
                return Color(
                    red: Double(red),
                    green: Double(green),
                    blue: Double(blue)
                ).opacity(Double(alpha))
            },
            set: { color in
                let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
                viewModel.updateMockupStyle {
                    $0.borderColor = .custom(
                        red: nsColor.redComponent,
                        green: nsColor.greenComponent,
                        blue: nsColor.blueComponent,
                        alpha: nsColor.alphaComponent
                    )
                }
            }
        )
    }

    private func shareSlider(
        _ title: LocalizedStringKey,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack {
                Text(title)
                    .font(DS.Typography.caption)
                Spacer()
                Text(valueText)
                    .font(DS.Typography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .accessibilityLabel(Text(title))
        }
    }
}

// MARK: - Swatch

private struct PresetSwatch: View {
    let preset: MockupPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if preset.style.background.isTransparent {
                    CheckerboardBackground(square: 4)
                } else {
                    RoundedRectangle(cornerRadius: DS.Corner.c6, style: .continuous)
                        .fill(presetBackgroundStyle(preset.style.background))
                }
                RoundedRectangle(cornerRadius: DS.Corner.c6, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }
            .frame(height: 26)
            .clipShape(RoundedRectangle(cornerRadius: DS.Corner.c6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(preset.localizedKey)))
        .accessibilityLabel(Text(LocalizedStringKey(preset.localizedKey)))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
    }
}

// MARK: - Background style

private func presetBackgroundStyle(_ background: MockupStyle.Background) -> AnyShapeStyle {
    switch background {
    case .transparent:
        return AnyShapeStyle(Color.clear)
    case .solid(let red, let green, let blue):
        return AnyShapeStyle(Color(
            red: Double(red),
            green: Double(green),
            blue: Double(blue)
        ))
    case .linear(let stops, let angle):
        let colors = stops.map {
            Color(red: Double($0.red), green: Double($0.green), blue: Double($0.blue))
        }
        return AnyShapeStyle(LinearGradient(
            colors: colors,
            startPoint: angle >= 90 ? .bottomLeading : .topLeading,
            endPoint: angle >= 90 ? .topTrailing : .bottomTrailing
        ))
    }
}

// MARK: - Checkerboard

struct CheckerboardBackground: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let base = Color(nsColor: .textBackgroundColor)
            let alternate = Color(nsColor: .controlBackgroundColor)
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(base)
            )
            let columns = Int(ceil(size.width / max(square, 1)))
            let rows = Int(ceil(size.height / max(square, 1)))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * square,
                        y: CGFloat(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(alternate))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityHidden(true)
    }
}

private enum BorderColorMode: Hashable {
    case automatic
    case black
    case white
    case custom
}
