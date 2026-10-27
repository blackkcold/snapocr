import AnnotationCore
import AppKit
import Testing

@testable import EditorInteractionTests

/// 裁剪是唯一一种「文档还没变、但马上会变」的编辑。关窗守卫必须把它
/// 当成未保存内容，否则在结果落回文档前关窗会静默丢掉这次裁剪。
@MainActor
struct EditorCropLifecycleTests {
    private func image() throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: 320, height: 240, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        return try #require(context.makeImage())
    }

    @Test func cropInFlightCountsAsUnsavedWork() throws {
        let model = EditorViewModel(image: try image())
        model.markSaved()
        #expect(!model.hasUnsavedChanges)

        model.isApplyingCrop = true
        #expect(model.hasUnsavedChanges)

        model.isApplyingCrop = false
        #expect(!model.hasUnsavedChanges)
    }
}
