import Foundation

// MARK: - EditorViewModel Close Flow

extension EditorViewModel {
    /// 记录一次文档变更。
    func markChanged() {
        changeCount &+= 1
    }

    /// 记录当前文档已写入磁盘或历史。
    func markSaved() {
        savedChangeCount = changeCount
    }

    /// 关闭编辑器；有未保存标注时先询问，而不是直接丢弃。
    public func requestClose() {
        if hasUnsavedChanges {
            showsCloseConfirmation = true
        } else {
            onClose?()
        }
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
