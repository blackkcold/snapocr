import AnnotationCore
import AppKit
import Testing

/// 多标签的核心不变量：新截图不得销毁已有文档；同一历史条目只开一个标签。
@MainActor
struct EditorWorkspaceTests {
  private func image(_ width: Int = 320) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: 240, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: 240))
    return try #require(context.makeImage())
  }

  @Test func openingASecondImageKeepsTheFirstTab() throws {
    let workspace = EditorWorkspace()
    let first = try #require(workspace.open(image: try image(100), context: .standard))
    let second = try #require(workspace.open(image: try image(200), context: .standard))

    #expect(workspace.tabs.count == 2)
    #expect(workspace.tabs.contains { $0.id == first.id })
    #expect(workspace.activeTabID == second.id)
  }

  @Test func openingTheSameHistoryEntryActivatesExistingTab() throws {
    let workspace = EditorWorkspace()
    let entryID = UUID()
    let context = EditorCaptureContext.capture(
      image: try image(), captureMode: "area", sourceEntryID: entryID)

    let first = try #require(workspace.open(image: try image(), context: context))
    let again = try #require(workspace.open(image: try image(), context: context))

    #expect(workspace.tabs.count == 1)
    #expect(first.id == again.id)
  }

  @Test func dirtyTabWaitsForConfirmation() throws {
    let workspace = EditorWorkspace()
    let tab = try #require(workspace.open(image: try image(), context: .standard))
    tab.viewModel.markSaved()
    tab.viewModel.addNode(
      AnnotationNode(
        tool: .rect,
        points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.4)]
      ))

    workspace.requestClose(tab.id)

    #expect(workspace.showsCloseConfirmation)
    #expect(workspace.tabs.count == 1)
  }

  @Test func cleanTabClosesImmediately() throws {
    let workspace = EditorWorkspace()
    workspace.closeWindowAction = {}
    let tab = try #require(workspace.open(image: try image(), context: .standard))
    tab.viewModel.markSaved()

    workspace.requestClose(tab.id)

    #expect(workspace.tabs.isEmpty)
    #expect(!workspace.showsCloseConfirmation)
  }

  @Test func tabLimitIsEnforced() throws {
    let workspace = EditorWorkspace()
    for _ in 0..<EditorWorkspace.maxTabs {
      _ = workspace.open(image: try image(), context: .standard)
    }

    #expect(workspace.open(image: try image(), context: .standard) == nil)
    #expect(workspace.tabs.count == EditorWorkspace.maxTabs)
  }
}
