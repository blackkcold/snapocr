import SwiftUI
import AppKit
import AnnotationCore

struct EditorView: View {
    @StateObject private var editorVM: EditorViewModel

    init(image: CGImage, context: EditorCaptureContext = .standard) {
        self._editorVM = StateObject(wrappedValue: EditorViewModel(image: image, context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolPickerView(
                selectedTool: Binding(
                    get: { editorVM.selectedTool },
                    set: { tool in
                        editorVM.activateTool(tool)
                    }
                ),
                selectedPreset: $editorVM.selectedPreset,
                selectedColor: Binding(
                    get: { editorVM.selectedColor },
                    set: { color in
                        editorVM.setSelectedColor(color)
                    }
                ),
                strokeWidth: Binding(
                    get: { editorVM.strokeWidth },
                    set: { width in
                        editorVM.strokeWidth = width
                        editorVM.selectedPreset = .custom
                        if editorVM.selectedNode != nil {
                            editorVM.updateSelectedStyle()
                        }
                    }
                ),
                isOCRRunning: editorVM.isOCRRunning,
                ocrLineCount: editorVM.ocrLines.count,
                isBarcodeScanning: editorVM.isBarcodeScanning,
                isVerticalTrimAvailable: editorVM.supportsVerticalTrim,
                isVerticalTrimActive: editorVM.isVerticalTrimEnabled,
                onPresetSelected: editorVM.applyPreset,
                onVerticalTrim: editorVM.activateVerticalTrim,
                onRunOCR: editorVM.startOCR,
                onCopyAllOCR: editorVM.copyAllOCRText,
                onScanBarcodes: editorVM.scanBarcodes
            )

            HSplitView {
                if let doc = editorVM.document {
                    EditableAnnotationCanvasView(
                        image: doc.baseImage,
                        nodes: doc.nodes,
                        tool: editorVM.selectedTool,
                        color: editorVM.cgColor,
                        lineWidth: editorVM.strokeWidth,
                        opacity: editorVM.annotationOpacity,
                        fillColor: editorVM.fillEnabled ? NSColor(editorVM.fillColor).cgColor : nil,
                        strokeStyle: editorVM.strokeStyle,
                        cornerRadius: editorVM.cornerRadius,
                        arrowStyle: editorVM.arrowStyle,
                        fontName: editorVM.fontName,
                        fontSize: editorVM.fontSize,
                        textAlignment: editorVM.textAlignment,
                        blurMode: editorVM.blurMode,
                        blurIntensity: editorVM.blurIntensity,
                        selectedNodeID: editorVM.selectedNodeID,
                        ocrLines: editorVM.ocrLines,
                        showsOCROverlay: editorVM.showsOCROverlay,
                        verticalCropOnly: editorVM.isVerticalTrimEnabled,
                        dominantColorCount: editorVM.dominantColorCount,
                        onNodeCreated: { node in
                            editorVM.addNode(node)
                        },
                        onNodeUpdated: editorVM.updateNode,
                        onSelectionChanged: editorVM.selectNode,
                        onDeleteSelection: editorVM.removeSelectedNode,
                        onTextRequested: { point in
                            editorVM.beginTextEntry(at: point)
                        },
                        onTextEditRequested: editorVM.beginTextEditing,
                        textEntryID: editorVM.textEntryID,
                        textEntryNode: editorVM.pendingTextNode,
                        onTextCommit: { text in
                            editorVM.textDraft = text
                            editorVM.commitTextEntry()
                        },
                        onTextCancel: editorVM.cancelTextEntry,
                        onOCRLinesCopied: editorVM.copyOCRLines,
                        onOCRTextCopied: editorVM.copyOCRSelection,
                        onOCRLineAsAnnotation: editorVM.addOCRLineAsAnnotation,
                        onColorPicked: editorVM.handleColorPicked,
                        onRegionColorsPicked: editorVM.handleRegionColorsPicked
                    )
                    .frame(minWidth: 500, minHeight: 400)
                } else {
                    ProgressView("Loading image…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if editorVM.selectedNode != nil
                    || editorVM.selectedTool.annotationTool != nil
                    || editorVM.selectedTool == .picker {
                    AnnotationInspectorView(viewModel: editorVM)
                }
            }

            bottomBar
                .disabled(editorVM.isEnteringText)
        }
        .frame(minWidth: 640, minHeight: 480)
        .toast(message: $editorVM.toastMessage)
        .onAppear {
            editorVM.onClose = {
                NSApplication.shared.keyWindow?.close()
            }
        }
        .onDisappear { editorVM.cancelTextEntry() }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                editorVM.cancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                editorVM.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!editorVM.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo (⌘Z)")

            Button {
                editorVM.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!editorVM.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo (⇧⌘Z)")

            Divider()
                .frame(height: 18)

            Toggle(isOn: $editorVM.showsOCROverlay) {
                Image(systemName: "text.viewfinder")
            }
            .toggleStyle(.button)
            .help("Show or hide recognized text regions")

            Menu {
                Button("Save as New Record") {
                    Task { await editorVM.saveToHistory(mode: .newRecord) }
                }
                if editorVM.canOverwriteOriginal {
                    Button("Overwrite Original Record") {
                        Task { await editorVM.saveToHistory(mode: .overwriteOriginal) }
                    }
                }
            } label: {
                Label("Save to History", systemImage: "square.and.arrow.down.on.square")
            }
            .keyboardShortcut("h", modifiers: [.command])
            .help("Save the annotated image into history")
            .disabled(editorVM.isEnteringText)

            Button("Copy") {
                editorVM.copyToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy annotated image to clipboard")

            Button("Save") {
                editorVM.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }
}
