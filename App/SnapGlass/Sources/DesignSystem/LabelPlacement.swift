import CoreGraphics

/// 浮在光标旁的标签定位。
///
/// 规则只有一份：默认放在光标右下；右缘不够翻到左侧，上缘不够翻到下方，
/// 最后再把整个矩形夹进可见区域并留出内边距。绘制与失效矩形都走这里。
enum LabelPlacement {
    static func rect(
        size: CGSize,
        near point: CGPoint,
        offset: CGSize = CGSize(width: 14, height: 14),
        inside bounds: CGRect,
        inset: CGFloat = 8
    ) -> CGRect {
        var origin = CGPoint(x: point.x + offset.width, y: point.y + offset.height)

        if origin.x + size.width > bounds.maxX - inset {
            origin.x = point.x - offset.width - size.width
        }
        if origin.y + size.height > bounds.maxY - inset {
            origin.y = point.y - offset.height - size.height
        }

        let minX = bounds.minX + inset
        let maxX = max(bounds.maxX - inset - size.width, minX)
        let minY = bounds.minY + inset
        let maxY = max(bounds.maxY - inset - size.height, minY)

        origin.x = min(max(origin.x, minX), maxX)
        origin.y = min(max(origin.y, minY), maxY)

        return CGRect(origin: origin, size: size).integral
    }
}
