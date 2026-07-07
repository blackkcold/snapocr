import SwiftUI
import AnnotationCore

struct ToolPickerView: View {
    @Binding var selectedTool: AnnotationToolType
    @Binding var selectedColor: Color
    @Binding var strokeWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationToolType.allCases, id: \.self) { tool in
                toolButton(tool)
            }

            Divider()
                .frame(height: 22)

            ColorPicker("", selection: $selectedColor)
                .frame(width: 26, height: 26)
                .labelsHidden()
                .help("Annotation color")

            Divider()
                .frame(height: 22)

            Picker("Width", selection: $strokeWidth) {
                ForEach([1, 2, 3, 5, 8], id: \.self) { w in
                    Text("\(w) px").tag(CGFloat(w))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 62)
            .help("Stroke width")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(10)
    }

    private func toolButton(_ tool: AnnotationToolType) -> some View {
        Button {
            selectedTool = tool
        } label: {
            Image(systemName: iconFor(tool))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedTool == tool ? Color.accentColor.opacity(0.18) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    selectedTool == tool ? Color.accentColor.opacity(0.5) : .clear,
                    lineWidth: 1
                )
        )
        .help(toolName(tool))
    }

    private func iconFor(_ tool: AnnotationToolType) -> String {
        switch tool {
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .text: return "textformat"
        case .pen: return "pencil.tip"
        case .highlight: return "highlighter"
        case .blur: return "drop.halffull"
        case .crop: return "crop"
        }
    }

    private func toolName(_ tool: AnnotationToolType) -> String {
        switch tool {
        case .arrow: return "Arrow"
        case .rect: return "Rectangle"
        case .text: return "Text"
        case .pen: return "Pen"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .crop: return "Crop"
        }
    }
}
