import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - SCKAdapter Helpers

extension SCKAdapter {
    static func outputScale(for display: SCDisplay, options: CaptureOptions) -> CGFloat {
        guard options.highResolution else { return 1 }
        let nativeScale = pixelScale(imageWidth: display.width, displayFrame: display.frame)
        let backingScale = NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? UInt32 else {
                return false
            }
            return screenNumber == display.displayID
        }?.backingScaleFactor ?? 1
        return max(1, nativeScale, backingScale)
    }

    static func pixelScale(imageWidth: Int, displayFrame: CGRect) -> CGFloat {
        guard imageWidth > 0, displayFrame.width > 0 else { return 1 }
        return CGFloat(imageWidth) / displayFrame.width
    }

    /// 选区 → 像素裁剪矩形。
    ///
    /// 数学部分已下沉到 `RegionPixelMapping`（public），供 App 层直接复用：
    /// 动作栏的条码识别要用同一套换算裁剪预截原图。
    static func pixelCropRect(
        areaRect: CGRect,
        displayFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        RegionPixelMapping.pixelCropRect(
            areaRect: areaRect,
            displayFrame: displayFrame,
            imageSize: imageSize
        )
    }

    /// 从 `SCDisplay` 构造 `CaptureDisplayInfo`
    func displayInfo(for display: SCDisplay) -> CaptureDisplayInfo {
        let scaleFactor: CGFloat = {
            let screens = NSScreen.screens
            for screen in screens {
                if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                   screenNumber == display.displayID {
                    return screen.backingScaleFactor
                }
            }
            return 2.0
        }()

        return CaptureDisplayInfo(
            displayID: display.displayID,
            scaleFactor: scaleFactor,
            frame: display.frame
        )
    }
}
