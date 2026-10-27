import CoreGraphics
import Testing

@testable import EditorInteractionTests

/// 标签夹取的四条边与极小画布。绘制和失效共用 `colorLabelRect`，
/// 所以这里只验证几何规则本身。
struct LabelPlacementTests {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let size = CGSize(width: 100, height: 40)
    private let inset: CGFloat = 8

    @Test func flipsToLeftNearRightEdge() {
        let rect = LabelPlacement.rect(
            size: size,
            near: CGPoint(x: 795, y: 200),
            inside: bounds,
            inset: inset
        )
        #expect(rect.maxX <= bounds.maxX - inset)
        #expect(rect.minX >= bounds.minX + inset)
        #expect(rect.minX < 795)
    }

    @Test func flipsBelowNearTopEdge() {
        let rect = LabelPlacement.rect(
            size: size,
            near: CGPoint(x: 200, y: 590),
            inside: bounds,
            inset: inset
        )
        #expect(rect.maxY <= bounds.maxY - inset)
        #expect(rect.minY >= bounds.minY + inset)
        #expect(rect.minY < 590)
    }

    @Test func staysInsideNearBottomLeftCorner() {
        let rect = LabelPlacement.rect(
            size: size,
            near: CGPoint(x: 0, y: 0),
            inside: bounds,
            inset: inset
        )
        #expect(rect.minX >= bounds.minX + inset)
        #expect(rect.minY >= bounds.minY + inset)
        #expect(rect.maxX <= bounds.maxX - inset)
        #expect(rect.maxY <= bounds.maxY - inset)
    }

    @Test func fitsTinyCanvas() {
        let tiny = CGRect(x: 0, y: 0, width: 120, height: 80)
        let rect = LabelPlacement.rect(
            size: size,
            near: CGPoint(x: 118, y: 78),
            inside: tiny,
            inset: inset
        )
        #expect(rect.minX >= tiny.minX + inset)
        #expect(rect.minY >= tiny.minY + inset)
        #expect(rect.maxX <= tiny.maxX - inset)
        #expect(rect.maxY <= tiny.maxY - inset)
    }
}
