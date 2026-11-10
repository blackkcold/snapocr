import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotShelfEncodedAssets: Sendable {
    let originalData: Data
    let thumbnailData: Data
}

enum ScreenshotShelfAssetError: Error {
    case historyUnavailable
    case sessionStorageUnavailable
}

/// Image encoding and downsampling for the screenshot shelf.
///
/// Kept separate from the manager so the capture/history orchestration stays readable and the
/// SwiftLint file-length guard is not bypassed.
enum ScreenshotShelfAssetEncoder {
    static func encode(_ image: CGImage) -> ScreenshotShelfEncodedAssets? {
        guard let originalData = imageData(image, type: .png) else { return nil }
        guard let thumbnail = downsampledImage(image, maxPixel: 768),
              let thumbnailData = imageData(thumbnail, type: .jpeg, quality: 0.82) else {
            return nil
        }
        return ScreenshotShelfEncodedAssets(originalData: originalData, thumbnailData: thumbnailData)
    }

    static func previewImage(from image: CGImage, maxPixel: CGFloat = 768) -> CGImage? {
        downsampledImage(image, maxPixel: maxPixel)
    }

    static func displayThumbnail(from data: Data) -> Data? {
        guard let thumbnail = decodeThumbnail(from: data) else { return nil }
        return imageData(thumbnail, type: .jpeg, quality: 0.82)
    }

    static func decodeThumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func downsampledImage(_ image: CGImage, maxPixel: CGFloat) -> CGImage? {
        let scale = min(1, maxPixel / CGFloat(max(1, max(image.width, image.height))))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func imageData(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
