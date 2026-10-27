import AppKit
import BarcodeCore
import Testing

/// 结果浮层的布局与交互契约。
///
/// 这些用例不弹窗、不注入事件，只验证「点得到、选得中、不会漏点」这三件事：
/// 浮层最容易回归的地方恰好都不是像素，而是控件类型与命中分发。
@Suite("Barcode result panel")
@MainActor
struct BarcodeResultPanelTests {
    private let linkPayload = "https://example.com/very/long/path?token=abcdefghijklmnopqrstuvwxyz0123456789"
    private let textPayload = "订单号 20261027-0031\n金额 ¥1,280.00"

    private func makePanel(_ state: ScanState) -> BarcodeResultPanel {
        let panel = BarcodeResultPanel(
            frame: NSRect(x: 0, y: 0, width: BarcodeResultPanel.width, height: 220)
        )
        panel.update(state: state)
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    private func results(_ payloads: [(text: String, type: BarcodeType)]) -> ScanState {
        .results(
            payloads.map {
                BarcodeResult(payload: $0.text, type: $0.type, boundingBox: .zero, confidence: 1)
            }
        )
    }

    private func allViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let typed = view as? T { found.append(typed) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    private func button(_ tooltip: String, in panel: BarcodeResultPanel) -> NSButton? {
        allViews(NSButton.self, in: panel).first { $0.toolTip == tooltip }
    }

    private func center(of view: NSView, in panel: BarcodeResultPanel) -> NSPoint {
        let rect = view.convert(view.bounds, to: panel)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    @Test("网页链接：正文可选、按词换行、最多三行，主次按钮齐全")
    func webLinkLayout() {
        let panel = makePanel(results([(linkPayload, .qr)]))
        let field = allViews(NSTextField.self, in: panel).first { $0.isSelectable }

        #expect(field != nil)
        #expect(field?.stringValue == linkPayload)
        #expect(field?.isEditable == false)
        #expect(field?.maximumNumberOfLines == BarcodeResultPanel.payloadLines)
        #expect(field?.cell?.wraps == true)
        #expect(field?.preferredMaxLayoutWidth == BarcodeResultPanel.contentWidth)
        // 长链接至少占两行；旧实现固定单行 15pt。
        #expect((field?.frame.height ?? 0) > 20)
        #expect(panel.preferredSize.width == 360)

        #expect(button("Copy Content", in: panel)?.bezelColor == nil)
        #expect(button("Open Link", in: panel)?.bezelColor == .controlAccentColor)
        #expect(button("Scan Again", in: panel) != nil)
        #expect(button("Close", in: panel) != nil)
    }

    @Test("超长正文最多三行，不会把浮层拉高")
    func payloadStopsAtThreeLines() {
        let longPayload = "https://example.com/" + String(repeating: "segment/", count: 40)
        let panel = makePanel(results([(longPayload, .qr)]))
        let field = allViews(NSTextField.self, in: panel).first { $0.isSelectable }

        #expect(field != nil)
        // 11.5pt 等宽字体单行约 15pt：三行封顶应落在 46pt 以内。
        #expect((field?.frame.height ?? 0) > 20)
        #expect((field?.frame.height ?? 0) <= 46)
    }

    @Test("纯文本：只有复制主操作，不出现打开链接")
    func textPayloadLayout() {
        let panel = makePanel(results([(textPayload, .qr)]))

        #expect(button("Open Link", in: panel) == nil)
        #expect(button("Copy Content", in: panel)?.bezelColor == .controlAccentColor)
        #expect(panel.copyTargets.count == 1)
    }

    @Test("多条结果：逐条复制 + 全部复制，超过五行折叠")
    func multiLayout() {
        let payloads = (0..<7).map { (text: "https://example.com/item/\($0)", type: BarcodeType.qr) }
        let panel = makePanel(results(payloads))

        #expect(button("Copy All", in: panel) != nil)
        // 5 行逐条复制 + 1 个全部复制；多余两条不再建行。
        #expect(panel.copyTargets.count == 6)
        #expect(button("Open Link", in: panel) == nil)
    }

    @Test("空结果与失败：只留重新识别")
    func emptyAndFailureLayout() {
        let empty = makePanel(.empty)
        #expect(empty.copyTargets.isEmpty)
        #expect(button("Scan Again", in: empty) != nil)

        let failed = makePanel(.failed("截图失败：没有可用的截图"))
        #expect(failed.copyTargets.isEmpty)
        #expect(button("Scan Again", in: failed) != nil)
    }

    @Test("兜底点击：把点击补派给按钮，卡片内空白一律吞掉")
    func fallbackDispatch() throws {
        var copied: String?
        var opened: URL?
        let panel = makePanel(results([(linkPayload, .qr)]))
        panel.onCopy = { copied = $0 }
        panel.onOpenLink = { opened = $0 }

        let copy = try #require(button("Copy Content", in: panel))
        #expect(panel.handleClick(at: center(of: copy, in: panel)))
        #expect(copied == linkPayload)

        let open = try #require(button("Open Link", in: panel))
        #expect(panel.handleClick(at: center(of: open, in: panel)))
        #expect(opened?.absoluteString == linkPayload)

        // 卡片内的空白也必须返回 true：返回 false 会让选区视图把它当成「点空白」收起浮层。
        #expect(panel.handleClick(at: NSPoint(x: panel.bounds.midX, y: panel.bounds.maxY - 2)))
        // 卡片外的点不接管。
        #expect(!panel.handleClick(at: NSPoint(x: -10, y: 10)))
    }

    @Test("命中测试不会漏到选区视图")
    func hitTestingStaysInsidePanel() {
        let panel = makePanel(results([(linkPayload, .qr)]))
        #expect(panel.hitTest(NSPoint(x: panel.bounds.midX, y: panel.bounds.midY)) != nil)
        #expect(panel.hitTest(NSPoint(x: -10, y: 10)) == nil)
    }
}
