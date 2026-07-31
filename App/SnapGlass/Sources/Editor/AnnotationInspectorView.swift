import AnnotationCore
import SwiftUI

struct AnnotationInspectorView: View {
    @ObservedObject var viewModel: EditorViewModel

    private var currentTool: AnnotationToolType? {
        viewModel.selectedNode?.tool ?? viewModel.selectedTool.annotationTool
    }

    private var isEditingSelection: Bool {
        viewModel.selectedNode != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    isEditingSelection
                        ? "Edit \(currentTool?.rawValue.capitalized ?? "Annotation")"
                        : "New \(currentTool?.rawValue.capitalized ?? "Annotation")",
                    systemImage: "slider.horizontal.3"
                )
                    .font(.headline)
                Spacer()
                if isEditingSelection {
                    Button(role: .destructive, action: viewModel.removeSelectedNode) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete selected annotation")
                }
            }

            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Stroke")
                        Spacer()
                        ColorPicker("", selection: selectedColorBinding)
                            .labelsHidden()
                    }
                    HStack {
                        Text("Width")
                        Slider(value: strokeWidthBinding, in: 1...20, step: 1)
                        Text("\(Int(viewModel.strokeWidth))")
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                    HStack {
                        Text("Opacity")
                        Slider(value: opacityBinding, in: 0.1...1, step: 0.05)
                        Text("\(Int(viewModel.annotationOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
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
                .padding(8)
            }

            if currentTool == .rect {
                GroupBox("Rectangle") {
                    HStack {
                        Text("Corner radius")
                        Slider(value: cornerRadiusBinding, in: 0...80, step: 2)
                        Text("\(Int(viewModel.cornerRadius))")
                            .frame(width: 28, alignment: .trailing)
                    }
                    .padding(8)
                }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Font", selection: fontNameBinding) {
                            Text("Helvetica").tag("Helvetica")
                            Text("Helvetica Neue").tag("Helvetica Neue")
                            Text("Menlo").tag("Menlo")
                            Text("Avenir Next").tag("Avenir Next")
                        }
                        HStack {
                            Text("Size")
                            Slider(value: fontSizeBinding, in: 10...96, step: 1)
                            Text("\(Int(viewModel.fontSize))")
                                .frame(width: 28, alignment: .trailing)
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
                    .padding(8)
                }
            }

            if currentTool == .blur {
                GroupBox("Blur") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Mode", selection: blurModeBinding) {
                            Text("Gaussian").tag(AnnotationBlurMode.gaussian)
                            Text("Pixelate").tag(AnnotationBlurMode.pixelate)
                            Text("Mosaic").tag(AnnotationBlurMode.mosaic)
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("Intensity")
                            Slider(value: blurIntensityBinding, in: 0...1, step: 0.05)
                            Text("\(Int(viewModel.blurIntensity * 100))%")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    .padding(8)
                }
            }

            Label(
                isEditingSelection ? "Changes apply immediately" : "Used for the next annotation",
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
                    Button(action: { viewModel.moveSelectedNodeInLayer(by: -1) }) {
                        Image(systemName: "square.2.layers.3d.bottom.filled")
                    }
                    .help("Send backward")
                    Button(action: { viewModel.moveSelectedNodeInLayer(by: 1) }) {
                        Image(systemName: "square.2.layers.3d.top.filled")
                    }
                    .help("Bring forward")
                }
            }

            Spacer()
        }
        .padding(12)
        .frame(minWidth: 230, idealWidth: 260, maxWidth: 300)
        .background(.thinMaterial)
    }

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
