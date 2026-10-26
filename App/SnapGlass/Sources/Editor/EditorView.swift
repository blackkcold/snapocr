import SwiftUI
import AppKit
import AnnotationCore

struct EditorView: View {
    @StateObject private var editorVM: EditorViewModel
    private let context: EditorCaptureContext

    init(image: CGImage, context: EditorCaptureContext = .standard) {
        self.context = context
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
                zoomController: editorVM.canvasZoom,
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
                        isAdjustingStyle: editorVM.isAdjustingStyle,
                        ocrLines: editorVM.ocrLines,
                        showsOCROverlay: editorVM.showsOCROverlay,
                        verticalCropOnly: editorVM.isVerticalTrimEnabled,
                        dominantColorCount: editorVM.dominantColorCount,
                        zoomController: editorVM.canvasZoom,
                        onToolShortcut: { tool in
                            editorVM.activateTool(tool)
                        },
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
                        onTextDraftChanged: { text in
                            editorVM.textDraft = text
                        },
                        onOCRLinesCopied: editorVM.copyOCRLines,
                        onOCRTextCopied: editorVM.copyOCRSelection,
                        onOCRLineAsAnnotation: editorVM.addOCRLineAsAnnotation,
                        onColorPicked: editorVM.handleColorPicked,
                        onRegionColorsPicked: editorVM.handleRegionColorsPicked
                    )
                    .frame(minWidth: 500, minHeight: 400)
                }

                if editorVM.selectedNode != nil
                    || (editorVM.selectedTool.annotationTool != nil && editorVM.selectedTool != .crop)
                    || editorVM.selectedTool == .picker {
                    AnnotationInspectorView(viewModel: editorVM)
                }
            }

            bottomBar
                .disabled(editorVM.isEnteringText)
        }
        .frame(minWidth: 640, minHeight: 480)
        .task(id: context.sourceEntryID) {
            if let entryID = context.sourceEntryID {
                editorVM.attachSourceEntry(entryID)
            }
        }
        .toast(message: $editorVM.toastMessage)
        .background(
            EditorWindowCloseGuard(
                isDirty: { editorVM.hasUnsavedChanges && !editorVM.hasAcceptedClose },
                onBlocked: { editorVM.showsCloseConfirmation = true }
            )
        )
        .sheet(isPresented: $editorVM.showsCloseConfirmation) {
            closeConfirmation
        }
        .onAppear {
            editorVM.onClose = {
                AppWindowPresenter.window(id: "editor")?.close()
            }
            editorVM.onForceClose = {
                AppWindowPresenter.window(id: "editor")?.close()
            }
        }
        .onDisappear { editorVM.cancelTextEntry() }
    }

    /// Three-way choice shown when closing would discard annotations.
    private var closeConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save your annotations?")
                .font(.headline)

            Text("Closing the editor now discards the annotations on this screenshot.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Discard", role: .destructive) {
                    editorVM.discardAndClose()
                }
                Spacer()
                Button("Cancel") {
                    editorVM.showsCloseConfirmation = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    editorVM.saveThenClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
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
            .accessibilityLabel("Undo")

            Button {
                editorVM.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!editorVM.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo (⇧⌘Z)")
            .accessibilityLabel("Redo")

            Divider()
                .frame(height: 18)

            Toggle(isOn: $editorVM.showsOCROverlay) {
                Image(systemName: "text.viewfinder")
            }
            .toggleStyle(.button)
            .help("Show or hide recognized text regions")
            .accessibilityLabel("Show or hide recognized text regions")

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
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Save the annotated image into history (⇧⌘S)")
            .disabled(editorVM.isEnteringText)

            Button("Copy") {
                editorVM.copyContextually()
            }
            .keyboardShortcut("c", modifiers: .command)
            .help("Copy the annotated image to the clipboard (⌘C)")

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
