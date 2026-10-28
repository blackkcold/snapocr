import AnnotationCore
import SharedKit
import SwiftUI

struct AnnotationInspectorView: View {
    @ObservedObject var viewModel: EditorViewModel

    private var currentTool: AnnotationToolType? {
        viewModel.selectedNode?.tool ?? viewModel.selectedTool.annotationTool
    }

    private var isEditingSelection: Bool {
        viewModel.selectedNode != nil
    }

    private var isPickerActive: Bool {
        viewModel.selectedTool == .picker
    }

    /// 常驻检查器只在「有可编辑对象或即将创建标注」时显示控件；
    /// 其余时候显示空态，避免一排灰掉的控件看起来像坏了。
    /// 裁剪没有样式可调，选中裁剪工具时保持空态。
    private var hasContext: Bool {
        isEditingSelection || isPickerActive || (currentTool != nil && currentTool != .crop)
    }

    /// Localized tool name used in the inspector title. The raw enum value would
    /// show English identifiers inside every other language.
    private var toolDisplayName: LocalizedStringKey {
        switch currentTool {
        case .arrow: "Arrow"
        case .rect: "Rectangle"
        case .text: "Text"
        case .pen: "Pen"
        case .highlight: "Highlight"
        case .blur: "Blur"
        case .crop: "Crop"
        case .none: "Annotation"
        }
    }

    private var headerIcon: String {
        if isPickerActive { return "eyedropper" }
        if viewModel.selectedTool == .crop { return "crop" }
        return "slider.horizontal.3"
    }

    private var headerTitle: LocalizedStringKey {
        if isPickerActive { return "Color Picker" }
        if viewModel.selectedTool == .crop { return "Crop" }
        if isEditingSelection { return "Edit \(Text(toolDisplayName))" }
        if hasContext, currentTool != nil { return "New \(Text(toolDisplayName))" }
        return "Inspector"
    }

    private var emptyMessage: LocalizedStringKey {
        viewModel.selectedTool == .crop
            ? "Drag on the canvas to choose the crop area"
            : "Select an annotation to adjust its style"
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: DS.Space.s12) {
                HStack {
                    Label {
                        Text(headerTitle)
                    } icon: {
                        Image(systemName: headerIcon)
                    }
                    .font(.headline)

                    Spacer()

                    if isEditingSelection {
                        Button(role: .destructive, action: viewModel.removeSelectedNode) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .frame(width: DS.Hit.small, height: DS.Hit.small)
                        .contentShape(Rectangle())
                        .help("Delete selected annotation")
                        .accessibilityLabel("Delete selected annotation")
                    }
                }

                if hasContext {
                    controls
                } else {
                    emptyState
                }

                Spacer(minLength: 0)
            }
            .padding(DS.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 240, idealWidth: 240, maxWidth: 280)
        .glassSurface(
            Rectangle(),
            elevation: .floating,
            castsShadow: false,
            showsStroke: false
        )
        .overlay(alignment: .leading) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation inspector")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DS.Space.s8) {
            Image(systemName: "slider.horizontal.3")
                .font(DS.Typography.emptyStateIcon)
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Space.s24)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        GroupBox("Appearance") {
            VStack(alignment: .leading, spacing: DS.Space.s10) {
                HStack {
                    Text("Stroke")
                    Spacer()
                    ColorPicker("", selection: selectedColorBinding)
                        .labelsHidden()
                        .accessibilityLabel("Stroke color")
                }
                HStack {
                    Text("Width")
                    Slider(value: strokeWidthBinding, in: 1...20, step: 1) { editing in
                        if editing { viewModel.beginStyleEdit() } else { viewModel.endStyleEdit() }
                    }
                    Text("\(Int(viewModel.strokeWidth))")
                        .monospacedDigit()
                        .frame(width: DS.Space.s24, alignment: .trailing)
                }
                HStack {
                    Text("Opacity")
                    Slider(value: opacityBinding, in: 0.1...1, step: 0.05) { editing in
                        if editing { viewModel.beginStyleEdit() } else { viewModel.endStyleEdit() }
                    }
                    Text("\(Int(viewModel.annotationOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: DS.Space.s32 + DS.Space.s10, alignment: .trailing)
                }
                Picker("Stroke style", selection: strokeStyleBinding) {
                    ForEach(AnnotationStrokeStyle.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
                Toggle("Fill / text background", isOn: fillEnabledBinding)
                if viewModel.fillEnabled {
                    ColorPicker("Fill color", selection: fillColorBinding, supportsOpacity: true)
                }
            }
            .padding(DS.Space.s8)
        }

        if currentTool == .rect {
            GroupBox("Rectangle") {
                HStack {
                    Text("Corner radius")
                    Slider(value: cornerRadiusBinding, in: 0...80, step: 2) { editing in
                        if editing { viewModel.beginStyleEdit() } else { viewModel.endStyleEdit() }
                    }
                    Text("\(Int(viewModel.cornerRadius))")
                        .frame(width: DS.Space.s24, alignment: .trailing)
                }
                .padding(DS.Space.s8)
            }
        }

        if isPickerActive {
            pickerCard
        }

        if currentTool == .arrow {
            Picker("Arrowhead", selection: arrowStyleBinding) {
                ForEach(AnnotationArrowStyle.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
        }

        if currentTool == .text {
            GroupBox("Text") {
                VStack(alignment: .leading, spacing: DS.Space.s8) {
                    Picker("Font", selection: fontNameBinding) {
                        Text("Helvetica").tag("Helvetica")
                        Text("Helvetica Neue").tag("Helvetica Neue")
                        Text("Menlo").tag("Menlo")
                        Text("Avenir Next").tag("Avenir Next")
                    }
                    HStack {
                        Text("Size")
                        Slider(value: fontSizeBinding, in: 10...96, step: 1) { editing in
                            if editing { viewModel.beginStyleEdit() } else { viewModel.endStyleEdit() }
                        }
                        Text("\(Int(viewModel.fontSize))")
                            .frame(width: DS.Space.s24, alignment: .trailing)
                    }
                    Picker("Alignment", selection: textAlignmentBinding) {
                        Text("Left").tag(AnnotationTextAlignment.leading)
                        Text("Center").tag(AnnotationTextAlignment.center)
                        Text("Right").tag(AnnotationTextAlignment.trailing)
                    }
                    .pickerStyle(.segmented)
                    if isEditingSelection {
                        Button("Edit Text") {
                            if let node = viewModel.selectedNode {
                                viewModel.beginTextEditing(node)
                            }
                        }

                        Text("Drag a handle to scale proportionally. Hold Shift for free width and height scaling.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(DS.Space.s8)
            }
        }

        if currentTool == .blur {
            GroupBox("Blur") {
                VStack(alignment: .leading, spacing: DS.Space.s10) {
                    Picker("Mode", selection: blurModeBinding) {
                        Text("Gaussian").tag(AnnotationBlurMode.gaussian)
                        Text("Pixelate").tag(AnnotationBlurMode.pixelate)
                        Text("Mosaic").tag(AnnotationBlurMode.mosaic)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Intensity")
                        Slider(value: blurIntensityBinding, in: 0...1, step: 0.05) { editing in
                            if editing { viewModel.beginStyleEdit() } else { viewModel.endStyleEdit() }
                        }
                        Text("\(Int(viewModel.blurIntensity * 100))%")
                            .monospacedDigit()
                            .frame(width: DS.Space.s32 + DS.Space.s10, alignment: .trailing)
                    }
                }
                .padding(DS.Space.s8)
            }
        }

        Label(
            isEditingSelection
                ? LocalizedStringKey("Changes apply immediately")
                : LocalizedStringKey("Used for the next annotation"),
            systemImage: isEditingSelection ? "checkmark.circle" : "paintbrush"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if isEditingSelection {
            HStack {
                Button(action: viewModel.duplicateSelectedNode) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Spacer()
                Button(action: { viewModel.moveSelectedNodeInLayer(by: -1) }, label: {
                    Image(systemName: "square.2.layers.3d.bottom.filled")
                        .frame(width: DS.Hit.small, height: DS.Hit.small)
                        .contentShape(Rectangle())
                })
                .help("Send backward")
                .accessibilityLabel("Send backward")
                Button(action: { viewModel.moveSelectedNodeInLayer(by: 1) }, label: {
                    Image(systemName: "square.2.layers.3d.top.filled")
                        .frame(width: DS.Hit.small, height: DS.Hit.small)
                        .contentShape(Rectangle())
                })
                .help("Bring forward")
                .accessibilityLabel("Bring forward")
            }
        }
    }

    // MARK: - Bindings

    private var selectedColorBinding: Binding<Color> {
        liveBinding(\.selectedColor)
    }

    private var strokeWidthBinding: Binding<CGFloat> {
        liveBinding(\.strokeWidth)
    }

    private var opacityBinding: Binding<CGFloat> {
        liveBinding(\.annotationOpacity)
    }

    private var fillEnabledBinding: Binding<Bool> {
        liveBinding(\.fillEnabled)
    }

    private var fillColorBinding: Binding<Color> {
        liveBinding(\.fillColor)
    }

    private var strokeStyleBinding: Binding<AnnotationStrokeStyle> {
        liveBinding(\.strokeStyle)
    }

    private var cornerRadiusBinding: Binding<CGFloat> {
        liveBinding(\.cornerRadius)
    }

    private var arrowStyleBinding: Binding<AnnotationArrowStyle> {
        liveBinding(\.arrowStyle)
    }

    private var fontNameBinding: Binding<String> {
        liveBinding(\.fontName)
    }

    private var fontSizeBinding: Binding<CGFloat> {
        liveBinding(\.fontSize)
    }

    private var textAlignmentBinding: Binding<AnnotationTextAlignment> {
        liveBinding(\.textAlignment)
    }

    private var blurModeBinding: Binding<AnnotationBlurMode> {
        liveBinding(\.blurMode)
    }

    private var blurIntensityBinding: Binding<CGFloat> {
        liveBinding(\.blurIntensity)
    }

    private var pickerCard: some View {
        GroupBox("Color Picker") {
            VStack(alignment: .leading, spacing: DS.Space.s10) {
                Label(
                    "Click to copy a single color. Drag to sample a region.",
                    systemImage: "eyedropper"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let hover = viewModel.pickerHoverColor {
                    colorRow(hover, title: "Hover")
                }

                if let average = viewModel.pickerAverageColor {
                    colorRow(average, title: "Average")
                }

                if !viewModel.pickerDominantColors.isEmpty {
                    Text("Dominant colors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: DS.Space.s6) {
                        ForEach(
                            Array(viewModel.pickerDominantColors.enumerated()),
                            id: \.offset
                        ) { _, color in
                            swatch(color)
                        }
                    }
                }

                Text("Click a swatch to copy its hex value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(DS.Space.s8)
        }
    }

    private func colorRow(_ color: SampledColor, title: LocalizedStringKey) -> some View {
        Button {
            viewModel.copyColorToClipboard(color)
        } label: {
            HStack(spacing: DS.Space.s8) {
                swatch(color)
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(color.hexString)
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                    Text(color.rgbString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy \(color.hexString)")
    }

    private func swatch(_ color: SampledColor) -> some View {
        RoundedRectangle(cornerRadius: DS.Corner.c4)
            .fill(Color(sampled: color))
            .frame(width: 18, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Corner.c4)
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5)
            )
    }

    private func liveBinding<Value>(_ keyPath: ReferenceWritableKeyPath<EditorViewModel, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel[keyPath: keyPath] },
            set: { value in
                viewModel[keyPath: keyPath] = value
                viewModel.selectedPreset = .custom
                if viewModel.selectedNode != nil {
                    viewModel.updateSelectedStyle()
                }
            }
        )
    }
}
