import SwiftUI
import AppKit
import AnnotationCore

struct EditorView: View {
    @StateObject private var editorVM: EditorViewModel

    init(image: CGImage) {
        self._editorVM = StateObject(wrappedValue: EditorViewModel(image: image))
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
                onPresetSelected: editorVM.applyPreset,
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
                        onOCRLinesCopied: editorVM.copyOCRLines,
                        onOCRTextCopied: editorVM.copyOCRSelection,
                        onOCRLineAsAnnotation: editorVM.addOCRLineAsAnnotation
                    )
                    .frame(minWidth: 500, minHeight: 400)
                } else {
                    ProgressView("Loading image…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if editorVM.selectedNode != nil || editorVM.selectedTool.annotationTool != nil {
                    AnnotationInspectorView(viewModel: editorVM)
                }
            }

            bottomBar
        }
        .frame(minWidth: 640, minHeight: 480)
        .toast(message: $editorVM.toastMessage)
        .onAppear {
            editorVM.onClose = {
                NSApplication.shared.keyWindow?.close()
            }
        }
        .alert(editorVM.selectedNode?.tool == .text ? "Edit Text" : "Add Text", isPresented: $editorVM.isEnteringText) {
            TextField("Text", text: $editorVM.textDraft)
            Button("Cancel", role: .cancel) {
                editorVM.cancelTextEntry()
            }
            Button("Add") {
                editorVM.commitTextEntry()
            }
        }
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
