import AnnotationCore
import CaptureCore
import AppKit
import CoreText
import OCRCore
import SharedKit
import SwiftUI

extension EditableAnnotationCanvasNSView {
    /// 悬停手柄只重绘两个小方块，不碰整张画布。
    func updateHoveredHandle(at point: CGPoint) {
        let handle = selectedNode.flatMap { resizeHandle(at: point, for: $0) }
        guard handle != hoveredHandle else { return }

        var dirty = CGRect.null
        if let old = hoveredHandle, let node = selectedNode {
            dirty = dirty.union(handleInvalidationRect(old, for: node))
        }
        hoveredHandle = handle
        if let handle, let node = selectedNode {
            dirty = dirty.union(handleInvalidationRect(handle, for: node))
        }
        if !dirty.isNull {
            setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2))
        }
    }

    func handleInvalidationRect(
        _ handle: ResizeHandle,
        for node: AnnotationNode
    ) -> CGRect {
        let center = handlePoint(handle, for: node)
        return CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
    }

    /// 取色上限 30Hz：120Hz 触控板上的每一次 mouseMoved 都去裁 1×1 像素并把
    /// 整张 5K 画布标脏，会把主线程喂满。这里按帧率限流，并用一个补发任务保证
    /// 光标停下后色值仍然指向最终位置。
    private static let pickerSampleInterval: CFTimeInterval = 1.0 / 30.0

    func schedulePickerSample(at point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - pickerLastSampleTime
        if elapsed >= Self.pickerSampleInterval {
            pickerPendingWorkItem?.cancel()
            pickerPendingWorkItem = nil
            pickerPendingPoint = nil
            applyPickerSample(at: point)
            return
        }

        pickerPendingPoint = point
        guard pickerPendingWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pickerPendingWorkItem = nil
            guard let pending = self.pickerPendingPoint else { return }
            self.pickerPendingPoint = nil
            self.applyPickerSample(at: pending)
        }
        pickerPendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.pickerSampleInterval - elapsed), execute: item)
    }

    private func applyPickerSample(at point: CGPoint) {
        pickerLastSampleTime = ProcessInfo.processInfo.systemUptime

        let key = pickerSampleKey(at: point)
        guard key != pickerSampleKey || pickerHoverColor == nil else { return }
        pickerSampleKey = key

        let previousRect = pickerHoverColor == nil ? .zero : pickerLabelRect
        let color = sampledColor(at: point)
        pickerHoverColor = color

        let newRect = color.map { colorLabelRect(for: $0, near: point) } ?? .zero
        pickerLabelRect = newRect
        pickerLabelPoint = point

        let dirty = previousRect.union(newRect).insetBy(dx: -2, dy: -2)
        if dirty.isEmpty {
            needsDisplay = true
        } else {
            setNeedsDisplay(dirty)
        }
    }

    /// 光标所在的原图像素坐标；同一像素内不重复取色。
    private func pickerSampleKey(at point: CGPoint) -> String {
        guard let image,
              imageDisplayRect.contains(point),
              imageDisplayRect.width > 0,
              imageDisplayRect.height > 0 else {
            return ""
        }
        let normalized = normalizedPoint(point)
        let pixelX = Int(normalized.x * CGFloat(image.width))
        let pixelY = Int((1 - normalized.y) * CGFloat(image.height))
        return "\(pixelX),\(pixelY)"
    }

    /// Samples the color under a view point in the base image.
    func sampledColor(at point: CGPoint) -> SampledColor? {
        guard let image, imageDisplayRect.contains(point) else { return nil }
        let normalized = normalizedPoint(point)
        let pixel = CGPoint(
            x: normalized.x * CGFloat(image.width),
            y: (1 - normalized.y) * CGFloat(image.height)
        )
        return ColorSampler.pixelColor(in: image, at: pixel)
    }

    /// Samples the dominant colors over a view-space region.
    func sampledRegionColors(for viewRect: CGRect) -> [SampledColor] {
        guard let image, !viewRect.isEmpty else { return [] }
        let normalized = CGRect(
            x: (viewRect.minX - imageDisplayRect.minX) / imageDisplayRect.width,
            y: (viewRect.minY - imageDisplayRect.minY) / imageDisplayRect.height,
            width: viewRect.width / imageDisplayRect.width,
            height: viewRect.height / imageDisplayRect.height
        )
        let pixelRect = CGRect(
            x: normalized.minX * CGFloat(image.width),
            y: (1 - normalized.maxY) * CGFloat(image.height),
            width: normalized.width * CGFloat(image.width),
            height: normalized.height * CGFloat(image.height)
        )
        return ColorSampler.dominantColors(in: image, in: pixelRect, count: dominantColorCount)
    }

}
