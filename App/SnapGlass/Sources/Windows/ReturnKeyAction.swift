import SwiftUI

extension View {
    /// 回车打开当前选中项。
    ///
    /// macOS 14 才有 `onKeyPress`；13 上不加这个修饰符，保持原有行为。
    /// 只有在 `enabled` 为真（有选中项）时才接收回车，避免抢走搜索框的按键。
    @ViewBuilder
    func onReturnKey(enabled: Bool, action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onKeyPress(.return) {
                guard enabled else { return .ignored }
                action()
                return .handled
            }
        } else {
            self
        }
    }
}
