import BarcodeCore

// MARK: - 选区条码识别状态

/// 动作栏「识别」按钮驱动的状态机。
///
/// 识别是只读的：不产生截图产物、不写历史、不碰剪贴板（直到用户点复制）。
/// 单独成文件是为了让结果浮层可以在不引入选区视图的前提下被测试覆盖。
enum ScanState {
    /// 没有浮层。
    case idle
    /// 识别中。
    case scanning
    /// 有结果（引擎顺序 = 置信度降序）。
    case results([BarcodeResult])
    /// 选区内没有条码。
    case empty
    /// 识别或截图失败。
    case failed(String)

    /// 是否需要在选区上显示浮层。
    var isVisible: Bool {
        if case .idle = self { return false }
        return true
    }

    /// 是否处于识别中（动作栏按钮据此禁用）。
    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}
