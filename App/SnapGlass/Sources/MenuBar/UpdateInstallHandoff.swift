import AppKit
import Foundation

/// 更新包下载完成后的安装交接。
///
/// 顺序不可反转：只有 `open` 成功后才退出 App。先退出就没有进程能再发起
/// 挂载请求，用户会落到「App 消失、安装包也没打开」的状态。
@MainActor
final class UpdateInstallHandoff {
  /// 交接结果，决定调用方如何提示。
  enum Outcome: Equatable {
    /// 安装包已交给 LaunchServices，App 正在退出。
    case openedInstaller
    /// 编辑器有未保存标注，保留 App 运行。
    case deferredForUnsavedWork
    /// 安装包打不开，App 保持运行；字符串仅用于日志，不直接展示。
    case failed(String)
    /// 已有一次交接在途，本次调用被忽略。
    case ignored
  }

  typealias InstallerOpener = @MainActor @Sendable (URL) async throws -> Void
  typealias ApplicationQuitter = @MainActor @Sendable () -> Void
  typealias UnsavedWorkProbe = @MainActor @Sendable () -> Bool

  private let openInstaller: InstallerOpener
  private let quitApplication: ApplicationQuitter
  private let hasUnsavedWork: UnsavedWorkProbe
  private var isRunning = false

  /// - Parameters:
  ///   - openInstaller: 打开 DMG，默认用独立进程调用 `/usr/bin/open`。
  ///   - quitApplication: 退出 App，默认走 `NSApplication.terminate`。
  ///   - hasUnsavedWork: 是否存在未保存的编辑器标注。
  init(
    openInstaller: @escaping InstallerOpener = UpdateInstallHandoff.launchInstaller,
    quitApplication: @escaping ApplicationQuitter = { NSApplication.shared.terminate(nil) },
    hasUnsavedWork: @escaping UnsavedWorkProbe
  ) {
    self.openInstaller = openInstaller
    self.quitApplication = quitApplication
    self.hasUnsavedWork = hasUnsavedWork
  }

  /// 打开安装包并退出 App。
  ///
  /// 未保存标注优先于自动退出：宁可让用户手动收尾，也不能静默丢弃编辑内容。
  @discardableResult
  func run(dmgURL: URL) async -> Outcome {
    guard !isRunning else { return .ignored }
    guard !hasUnsavedWork() else { return .deferredForUnsavedWork }

    isRunning = true
    defer { isRunning = false }

    do {
      try await openInstaller(dmgURL)
    } catch {
      return .failed(error.localizedDescription)
    }
    quitApplication()
    return .openedInstaller
  }

  /// 用独立进程打开 DMG。
  ///
  /// 走 `Process` 而不是 `NSWorkspace.open`：后者是同步 IPC，会占住主线程；
  /// 子进程即使父进程立刻退出，也会被 launchd 收养并完成挂载。
  nonisolated static func launchInstaller(at url: URL) async throws {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = [url.path]
      try process.run()

      let deadline = Date().addingTimeInterval(10)
      while process.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard !process.isRunning else {
        process.terminate()
        throw UpdateInstallError.installerTimedOut
      }
      guard process.terminationStatus == 0 else {
        throw UpdateInstallError.installerLaunchFailed(process.terminationStatus)
      }
    }.value
  }
}

/// 安装交接失败的原因。
enum UpdateInstallError: LocalizedError, Sendable {
  case installerTimedOut
  case installerLaunchFailed(Int32)

  var errorDescription: String? {
    switch self {
    case .installerTimedOut:
      "The update installer did not finish opening in time."
    case .installerLaunchFailed(let status):
      "The update installer could not be opened (open exited with \(status))."
    }
  }
}
