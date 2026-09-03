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

    static func pixelCropRect(
        areaRect: CGRect,
        displayFrame: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard displayFrame.contains(areaRect), imageSize.width > 0, imageSize.height > 0 else {
            return nil
        }

        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let localX = areaRect.minX - displayFrame.minX
        let localY = areaRect.minY - displayFrame.minY
        let cropRect = CGRect(
            x: localX * scaleX,
            y: localY * scaleY,
            width: areaRect.width * scaleX,
            height: areaRect.height * scaleY
        ).integral
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let clamped = cropRect.intersection(imageBounds)
        return clamped.isEmpty ? nil : clamped
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
