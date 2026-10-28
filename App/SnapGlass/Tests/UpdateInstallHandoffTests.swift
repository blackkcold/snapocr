import Foundation
import Testing

@testable import WindowLifecycleStateTests

/// 下载完成后的安装交接：必须先打开安装包，再退出 App；
/// 未保存标注或打开失败时都不许退出。
@MainActor
struct UpdateInstallHandoffTests {
  private let dmgURL = URL(fileURLWithPath: "/tmp/SnapGlass-v0.9.6.dmg")

  @Test func opensInstallerBeforeQuitting() async {
    let recorder = Recorder()
    let handoff = UpdateInstallHandoff(
      openInstaller: { url in recorder.append("open:\(url.lastPathComponent)") },
      quitApplication: { recorder.append("quit") },
      hasUnsavedWork: { false }
    )

    let outcome = await handoff.run(dmgURL: dmgURL)

    #expect(outcome == .openedInstaller)
    #expect(recorder.events == ["open:SnapGlass-v0.9.6.dmg", "quit"])
  }

  @Test func keepsRunningWhenInstallerFails() async {
    let recorder = Recorder()
    let handoff = UpdateInstallHandoff(
      openInstaller: { _ in throw StubError.launchFailed },
      quitApplication: { recorder.append("quit") },
      hasUnsavedWork: { false }
    )

    let outcome = await handoff.run(dmgURL: dmgURL)

    #expect(outcome == .failed("stub launch failure"))
    #expect(recorder.events.isEmpty)
  }

  @Test func keepsRunningWhenEditorHasUnsavedWork() async {
    let recorder = Recorder()
    let handoff = UpdateInstallHandoff(
      openInstaller: { url in recorder.append("open:\(url.lastPathComponent)") },
      quitApplication: { recorder.append("quit") },
      hasUnsavedWork: { true }
    )

    let outcome = await handoff.run(dmgURL: dmgURL)

    #expect(outcome == .deferredForUnsavedWork)
    #expect(recorder.events.isEmpty)
  }

  @Test func ignoresConcurrentHandoff() async {
    let recorder = Recorder()
    let box = Box()
    let handoff = UpdateInstallHandoff(
      openInstaller: { url in
        let nested = await box.handoff?.run(dmgURL: url)
        recorder.append("nested:\(nested == .ignored)")
      },
      quitApplication: { recorder.append("quit") },
      hasUnsavedWork: { false }
    )
    box.handoff = handoff

    let outcome = await handoff.run(dmgURL: dmgURL)

    #expect(outcome == .openedInstaller)
    #expect(recorder.events == ["nested:true", "quit"])
  }
}

@MainActor
private final class Recorder {
  private(set) var events: [String] = []

  func append(_ event: String) {
    events.append(event)
  }
}

@MainActor
private final class Box {
  var handoff: UpdateInstallHandoff?
}

private enum StubError: LocalizedError {
  case launchFailed

  var errorDescription: String? { "stub launch failure" }
}
