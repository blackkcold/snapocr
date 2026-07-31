import CoreGraphics
import Foundation

/// Applies transparent freehand masks to captured images.
public enum SelectionMaskProcessor {
  /// Masks an image using points normalized to the image bounds.
  ///
  /// - Parameters:
  ///   - image: Source image captured from the freehand path's bounding rectangle.
  ///   - normalizedPath: Closed-path vertices normalized to `[0, 1]`.
  /// - Returns: An RGBA image with pixels outside the path made transparent.
  /// - Throws: `CaptureError.invalidRegion` for an incomplete path, or
  ///   `CaptureError.captureFailed` when the mask cannot be rendered.
  public static func apply(
    to image: CGImage,
    normalizedPath: [CGPoint]
  ) throws -> CGImage {
    guard normalizedPath.count >= 3 else {
      throw CaptureError.invalidRegion
    }

    guard
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw CaptureError.captureFailed(reason: "Unable to create freeform mask context")
    }

    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let path = CGMutablePath()
    path.move(to: pixelPoint(normalizedPath[0], width: width, height: height))
    for point in normalizedPath.dropFirst() {
      path.addLine(to: pixelPoint(point, width: width, height: height))
    }
    path.closeSubpath()

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.addPath(path)
    context.clip()
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let result = context.makeImage() else {
      throw CaptureError.captureFailed(reason: "Unable to render freeform selection")
    }
    return result
  }

  private static func pixelPoint(_ point: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
    CGPoint(
      x: min(max(point.x, 0), 1) * width,
      y: min(max(point.y, 0), 1) * height
    )
  }
}
