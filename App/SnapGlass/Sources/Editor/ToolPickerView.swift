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
    @ObservedObject var zoomController: CanvasZoomController
    let onPresetSelected: (AnnotationStylePreset) -> Void
    let onVerticalTrim: () -> Void
    let onRunOCR: () -> Void
    let onCopyAllOCR: () -> Void
    let onScanBarcodes: () -> Void

    var body: some View {
        // Narrow windows drop the secondary actions into an overflow menu
        // instead of squeezing (or clipping) the tool group.
        ViewThatFits(in: .horizontal, content: {
            fullControls
            compactControls
        })
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(10)
    }

    // MARK: - Layouts

    private var fullControls: some View {
        HStack(spacing: 6) {
            if isVerticalTrimAvailable {
                trimButton
                divider
            }

            toolGroup

            divider

            zoomControl

            divider

            presetPicker

            divider

            colorPicker

            divider

            widthPicker

            divider

            ocrControls

            barcodeControl
        }
        .fixedSize()
    }

    private var compactControls: some View {
        HStack(spacing: 6) {
            toolGroup

            divider

            zoomControl

            divider

            presetPicker

            divider

            colorPicker

            overflowMenu
        }
        .fixedSize()
    }

    private var overflowMenu: some View {
        Menu {
            Picker("Width", selection: $strokeWidth) {
                ForEach([1, 2, 3, 5, 8], id: \.self) { width in
                    Text("\(width) px").tag(CGFloat(width))
                }
            }

            Divider()

            if isVerticalTrimAvailable {
                Button(action: onVerticalTrim) {
                    Label("Trim Ends", systemImage: "arrow.up.and.line.horizontal.and.arrow.down")
                }
            }

            Button(action: onRunOCR) {
                Label("Run OCR Again", systemImage: "arrow.clockwise")
            }
            .disabled(isOCRRunning)

            Button(action: onCopyAllOCR) {
                Label("Copy All Recognized Text", systemImage: "doc.on.doc")
            }
            .disabled(ocrLineCount == 0)

            Button(action: onScanBarcodes) {
                Label("Scan Barcode", systemImage: "barcode.viewfinder")
            }
            .disabled(isBarcodeScanning)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More annotation tools")
        .help("More annotation actions")
    }

    // MARK: - Controls

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in
                if tool != .ocr {
                    toolButton(tool)
                }
            }
        }
    }

    private var trimButton: some View {
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
        .accessibilityLabel("Trim Ends")
    }

    private var presetPicker: some View {
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
        .accessibilityLabel("Style preset")
    }

    private var colorPicker: some View {
        ColorPicker("", selection: $selectedColor)
            .frame(width: 26, height: 26)
            .labelsHidden()
            .help("Annotation color")
            .accessibilityLabel("Annotation color")
    }

    private var widthPicker: some View {
        Picker("Width", selection: $strokeWidth) {
            ForEach([1, 2, 3, 5, 8], id: \.self) { width in
                Text("\(width) px").tag(CGFloat(width))
            }
        }
        .pickerStyle(.menu)
        .frame(width: 62)
        .help("Stroke width")
        .accessibilityLabel("Stroke width")
    }

    private var ocrControls: some View {
        HStack(spacing: 6) {
            if isOCRRunning {
                ProgressView()
                    .controlSize(.small)
                    .help("Recognizing text")
                    .accessibilityLabel("Recognizing text")
            } else {
                Button(action: onRunOCR) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Run OCR again")
                .accessibilityLabel("Run OCR again")
            }

            Button(action: onCopyAllOCR) {
                Label("\(ocrLineCount)", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .disabled(ocrLineCount == 0)
            .help("Copy all recognized text")
            .accessibilityLabel(ocrLineCount == 0
                                ? Text("Copy all recognized text")
                                : Text("Copy \(ocrLineCount) recognized lines"))
        }
    }

    private var barcodeControl: some View {
        Group {
            if isBarcodeScanning {
                ProgressView()
                    .controlSize(.small)
                    .help("Scanning barcodes")
                    .accessibilityLabel("Scanning barcodes")
            } else {
                Button(action: onScanBarcodes) {
                    Image(systemName: "qrcode.viewfinder")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scan Barcode")
                .help("Scan barcodes and copy decoded content")
            }
        }
    }

    /// Zoom readout plus in/out buttons. Percentages refer to the image's own
    /// pixels, so "100%" means one image pixel per point.
    private var zoomControl: some View {
        HStack(spacing: 2) {
            Button {
                zoomController.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(zoomController.isFit)
            .help("Zoom out (⌘−)")
            .accessibilityLabel("Zoom out")

            Menu {
                Button("Fit to Window") { zoomController.fit() }
                Button("Actual Size (100%)") { zoomController.actualSize() }
            } label: {
                zoomLabel
                    .frame(minWidth: 42)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom (⌘0 fits the window, ⌘1 shows actual size)")

            Button {
                zoomController.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(zoomController.scale >= 7.999)
            .help("Zoom in (⌘+)")
            .accessibilityLabel("Zoom in")
        }
    }

    @ViewBuilder
    private var zoomLabel: some View {
        if zoomController.isFit {
            Text("Fit")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else {
            Text(verbatim: "\(Int((zoomController.pixelScale * 100).rounded()))%")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
    }

    private var divider: some View {
        Divider().frame(height: 22)
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
        .help(tool.displayName)
        .accessibilityLabel(tool.displayName)
        .accessibilityAddTraits(selectedTool == tool ? .isSelected : [])
    }
}
