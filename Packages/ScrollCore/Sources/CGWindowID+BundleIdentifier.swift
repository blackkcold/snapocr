import AppKit
import CoreGraphics

// MARK: - CGWindowID Extension

extension CGWindowID {
    /// 获取与窗口关联的 bundle identifier。
    ///
    /// 先通过 `CGWindowListCopyWindowInfo` 获取窗口所属进程 PID，
    /// 再通过 `NSRunningApplication` 获取该进程的 bundle identifier。
    var bundleIdentifier: String? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            self
        ) as? [[String: Any]],
              let ownerPID = windowInfo.first?[kCGWindowOwnerPID as String] as? pid_t
        else {
            return nil
        }

        return NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
    }
}
