import CoreGraphics
import Foundation
import Testing
@testable import AnnotationCore

struct TextPreviewRegressionTests {
    @Test func tightTextRemainsVisibleWhenPreviewIsReduced() throws {
        let context = try #require(CGContext(data: nil, width: 2000, height: 1000,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let base = try #require(context.makeImage())
        var node = AnnotationNode(tool: .text, color: CGColor(gray: 1, alpha: 1),
            points: [CGPoint(x: 0.1, y: 0.1)], text: "Visible text", fontSize: 24)
        let size = TextTool().suggestedSize(for: node)
        node.normalizedRect = CGRect(x: 0.1, y: 0.1, width: size.width / 2000, height: size.height / 1000)
        var document = AnnotationDocument(baseImage: base)
        document.addNode(node)
        for dimension: CGFloat in [500, 800, 1200, 2000] {
            let rendered = try Renderer().render(document, maximumDimension: dimension)
            let bytes = try #require(rendered.dataProvider?.data)
            let pointer = try #require(CFDataGetBytePtr(bytes))
            let painted = (0..<CFDataGetLength(bytes)).filter { pointer[$0] > 0 }.count
            #expect(painted > 20, "Text disappeared at preview size \(dimension)")
        }
    }
}
