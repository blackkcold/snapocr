import SwiftUI
import AppKit
import AnnotationCore
import SharedKit

struct EditorView: View {
    @ObservedObject var editorVM: EditorViewModel
    private let context: EditorCaptureContext

    /// 检查器常驻开关（⌥⌘I）。默认常驻，避免选中标注时画布宽度跳动。
    @AppStorage(PreferenceKeys.editorInspectorVisible)
    private var showsInspector = PreferenceDefaults.editorInspectorVisible

    init(viewModel: EditorViewModel, context: EditorCaptureContext = .standard) {
        self.editorVM = viewModel
        self.context = context
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

                if showsInspector {
                    AnnotationInspectorView(viewModel: editorVM)
                }
            }

            bottomBar
                .disabled(editorVM.isEnteringText)
        }
        .overlay(alignment: .topTrailing) {
            if editorVM.isApplyingCrop {
                HStack(spacing: DS.Space.s6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing…")
                        .font(DS.Typography.caption)
                }
                .padding(.horizontal, DS.Space.s10)
                .padding(.vertical, DS.Space.s6)
                .glassSurface(Capsule(), elevation: .raised)
                .padding(DS.Space.s12)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minWidth: 740, minHeight: 480)
        .task(id: context.sourceEntryID) {
            if let entryID = context.sourceEntryID {
                editorVM.attachSourceEntry(entryID)
            }
        }
        .toast(message: $editorVM.toastMessage)
        .onDisappear { editorVM.cancelTextEntry() }
    }

    private var bottomBar: some View {
        HStack(spacing: DS.Space.s10) {
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
            .disabled(!editorVM.canUndo || editorVM.isApplyingCrop)
            .keyboardShortcut("z", modifiers: .command)
            .help(editorVM.isApplyingCrop ? Text("Processing crop…") : Text("Undo (⌘Z)"))
            .accessibilityLabel("Undo")

            Button {
                editorVM.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!editorVM.canRedo || editorVM.isApplyingCrop)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help(editorVM.isApplyingCrop ? Text("Processing crop…") : Text("Redo (⇧⌘Z)"))
            .accessibilityLabel("Redo")

            Divider()
                .frame(height: DS.Space.s18)

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
            .disabled(editorVM.isEnteringText || editorVM.isApplyingCrop || editorVM.isWritingImage)

            Button("Copy") {
                editorVM.copyContextually()
            }
            .keyboardShortcut("c", modifiers: .command)
            .help(editorVM.isApplyingCrop
                  ? Text("Processing crop…")
                  : Text("Copy the annotated image to the clipboard (⌘C)"))
            .disabled(editorVM.isApplyingCrop || editorVM.isWritingImage)

            Button("Save") {
                editorVM.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .help(editorVM.isApplyingCrop
                  ? Text("Processing crop…")
                  : Text("Save the annotated image (⌘S)"))
            .disabled(editorVM.isApplyingCrop || editorVM.isWritingImage)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, DS.Space.s14)
        .padding(.vertical, DS.Space.s9)
        .glassSurface(Rectangle(), elevation: .raised, castsShadow: false, showsStroke: false)
        .overlay(alignment: .top) { Divider() }
    }
}
