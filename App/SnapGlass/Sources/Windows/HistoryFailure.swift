import Foundation

/// 历史窗口的一次失败，以及它应该给出的出口。
///
/// 之前所有失败都套同一个「重试」按钮：复制失败按重试还是复制失败，
/// 资源丢失按重试永远不会好。把「发生了什么」和「能做什么」分开，
/// 映射关系可以单独测试。
struct HistoryFailure: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 读取历史列表失败。
        case load
        /// 复制图片失败（剪贴板或解码）。
        case copy
        /// 记录还在，但原始图片缺失或损坏。
        case storage
        /// 其它动作失败：删除、收藏、清空、导出等。
        case action
    }

    enum Recovery: Equatable {
        case retryLoad
        case retryCopy
        case revealStorage
        case dismiss
    }

    let id = UUID()
    let kind: Kind
    let message: String
    /// 复制失败时指向原条目，用于「再次复制」。
    let entryID: UUID?

    init(kind: Kind, message: String, entryID: UUID? = nil) {
        self.kind = kind
        self.message = message
        self.entryID = entryID
    }

    var recovery: Recovery {
        Self.recovery(for: kind)
    }

    static func recovery(for kind: Kind) -> Recovery {
        switch kind {
        case .load: .retryLoad
        case .copy: .retryCopy
        case .storage: .revealStorage
        case .action: .dismiss
        }
    }
}
