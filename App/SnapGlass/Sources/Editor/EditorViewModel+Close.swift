import AnnotationCore
import Foundation

// MARK: - EditorViewModel Close Flow

extension EditorViewModel {
    /// 记录一次文档变更。
    func markChanged() {
        changeCount &+= 1
    }

    /// 记录当前文档已写入磁盘或历史。
    func markSaved() {
        resetSavedSnapshot()
    }

    /// 记录「实际写入的那份文档」为干净基线。
    ///
    /// 保存面板是非模态的：面板打开期间用户仍可继续编辑。若写完后用
    /// 当前文档建基线，这些新改动会被误判为已保存，关窗时静默丢失。
    func markSaved(document saved: AnnotationDocument?) {
        guard let saved else {
            resetSavedSnapshot()
            return
        }
        savedDocumentNodes = saved.nodes
        savedBaseImage = saved.baseImage
        savedChangeCount = changeCount
        hasSavedSnapshot = true
    }

    /// Captures the current document as the clean baseline.
    func resetSavedSnapshot() {
        savedDocumentNodes = document?.nodes ?? []
        savedBaseImage = document?.baseImage
        savedChangeCount = changeCount
        hasSavedSnapshot = document != nil
    }

    /// 关闭编辑器；有未保存标注时先询问，而不是直接丢弃。
    ///
    /// 多标签下确认框由 `EditorWorkspace` 统一持有，单个 ViewModel 不能再
    /// 自己置 `showsCloseConfirmation`——那个 sheet 已随窗口级守卫上移。
    public func requestClose() {
        guard let onClose else {
            if hasUnsavedChanges {
                showsCloseConfirmation = true
            }
            return
        }
        onClose()
    }

    /// 用户选择放弃标注。
    public func discardAndClose() {
        showsCloseConfirmation = false
        hasAcceptedClose = true
        onForceClose?()
    }

    /// 用户选择保存标注；文件写成功后再关闭窗口。
    public func saveThenClose() {
        save { [weak self] didSave in
            guard let self, didSave else { return }
            self.showsCloseConfirmation = false
            self.hasAcceptedClose = true
            self.onForceClose?()
        }
    }
}
