import SwiftUI
import AnnotationCore

struct ToolPickerView: View {
    @Binding var selectedTool: EditorTool
    @Binding var selectedPreset: AnnotationStylePreset
    @Binding var selectedColor: Color
    @Binding var strokeWidth: CGFloat
    let isOCRRunning: Bool
    let ocrLineCount: Int
    let isBarcodeScanning: Bool
    let isVerticalTrimAvailable: Bool
    let isVerticalTrimActive: Bool
    let onPresetSelected: (AnnotationStylePreset) -> Void
    let onVerticalTrim: () -> Void
    let onRunOCR: () -> Void
    let onCopyAllOCR: () -> Void
    let onScanBarcodes: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isVerticalTrimAvailable {
                Button(action: onVerticalTrim) {
                    Label("Trim Ends", systemImage: "arrow.up.and.line.horizontal.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isVerticalTrimActive ? Color.accentColor.opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isVerticalTrimActive ? Color.accentColor.opacity(0.5) : .clear,
                            lineWidth: 1
                        )
                )
                .help("Adjust only the top and bottom edges of a long screenshot")

                Divider()
                    .frame(height: 22)
            }

            ForEach(EditorTool.allCases) { tool in
                toolButton(tool)
            }

            Divider()
                .frame(height: 22)

            Picker("Preset", selection: Binding(
                get: { selectedPreset },
                set: { preset in
                    selectedPreset = preset
                    onPresetSelected(preset)
                }
            )) {
                ForEach(AnnotationStylePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 108)

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

            Divider()
                .frame(height: 22)

            if isOCRRunning {
                ProgressView()
                    .controlSize(.small)
                    .help("Recognizing text")
            } else {
                Button(action: onRunOCR) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Run OCR again")
            }

            Button(action: onCopyAllOCR) {
                Label("\(ocrLineCount)", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .disabled(ocrLineCount == 0)
            .help("Copy all recognized text")

            Divider()
                .frame(height: 22)

            if isBarcodeScanning {
                ProgressView()
                    .controlSize(.small)
                    .help("Scanning barcodes")
            } else {
                Button(action: onScanBarcodes) {
                    Image(systemName: "qrcode.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan Barcode")
                .help("Scan barcodes and copy decoded content")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(10)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        Button {
            selectedTool = tool
        } label: {
            Image(systemName: tool.iconName)
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
        .help(
            tool == .ocr
                ? "Drag to select text. Double-click a word, triple-click a line, or hold Shift to extend."
                : tool.displayName
        )
    }
}
