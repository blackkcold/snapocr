import SwiftUI
import AppKit
import AnnotationCore

struct EditorView: View {
    private let sourceImage: CGImage
    @StateObject private var editorVM: EditorViewModel

    init(image: CGImage) {
        self.sourceImage = image
        let vm = EditorViewModel()
        vm.loadImage(image)
        self._editorVM = StateObject(wrappedValue: vm)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolPickerView(
                selectedTool: $editorVM.selectedTool,
                selectedColor: $editorVM.selectedColor,
                strokeWidth: $editorVM.strokeWidth
            )

            ZStack {
                if let doc = editorVM.document {
                    AnnotationCanvasView(
                        image: doc.baseImage,
                        nodes: doc.nodes,
                        tool: editorVM.selectedTool,
                        color: editorVM.cgColor,
                        lineWidth: editorVM.strokeWidth,
                        onNodeCreated: { node in
                            editorVM.addNode(node)
                        }
                    )
                } else {
                    ProgressView("Loading image…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
