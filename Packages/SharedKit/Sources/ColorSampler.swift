import CoreGraphics
import Foundation

/// A single RGBA color sample represented in the sRGB color space.
public struct SampledColor: Equatable, Sendable, Codable {
  /// Red component (0–255).
  public let red: UInt8
  /// Green component (0–255).
  public let green: UInt8
  /// Blue component (0–255).
  public let blue: UInt8
  /// Alpha component (0–255).
  public let alpha: UInt8

  /// Creates a color sample from raw sRGB components.
  public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// The `#RRGGBB` hex representation, ignoring alpha.
  public var hexString: String {
    ColorSampler.hexString(red: red, green: green, blue: blue)
  }

  /// The `rgb(r, g, b)` decimal representation, ignoring alpha.
  public var rgbString: String {
    "rgb(\(red), \(green), \(blue))"
  }
}

/// Pure image color sampling helpers.
///
/// All sampling converts pixels into the sRGB color space first, so the
/// reported values match what a user perceives on a typical display rather
/// than the display's native (e.g. P3) color space. Functions accept a
/// `CGImage` together with coordinates in image space, where the origin is
/// the top-left scanline and `y` increases downward (Quartz convention).
public enum ColorSampler {
  /// Maximum dimension (in points) used when downsampling a region before
  /// computing dominant colors. Keeps bucketing fast for full-screen images.
  private static let dominantSampleDimension: Int = 96

  /// Maximum dimension (in points) used when downsampling a region before
  /// computing its average color.
  private static let averageSampleDimension: Int = 64

  /// Samples the color of a single pixel.
  ///
  /// - Parameters:
  ///   - image: The source image.
  ///   - point: A point in image space (top-left origin). Coordinates are
  ///     clamped to the image bounds, so out-of-range values are safe.
  /// - Returns: The sampled color in sRGB, or `nil` if sampling fails.
  public static func pixelColor(in image: CGImage, at point: CGPoint) -> SampledColor? {
    guard image.width > 0, image.height > 0 else { return nil }
    let pixelX = min(max(Int(point.x.rounded(.down)), 0), image.width - 1)
    let pixelY = min(max(Int(point.y.rounded(.down)), 0), image.height - 1)
    let rect = CGRect(x: pixelX, y: pixelY, width: 1, height: 1)
    guard let pixels = drawRegion(image, in: rect, outputWidth: 1, outputHeight: 1),
      pixels.count >= 4
    else { return nil }
    return SampledColor(
      red: pixels[0],
      green: pixels[1],
      blue: pixels[2],
      alpha: pixels[3]
    )
  }

  /// Computes the average color over a rectangular region.
  ///
  /// The region is downsampled to a bounded buffer before averaging, which
  /// both avoids allocating buffers proportional to full-screen images and
  /// smooths out sub-pixel noise.
  ///
  /// - Parameters:
  ///   - image: The source image.
  ///   - rect: A rectangle in image space (top-left origin). Clamped to bounds.
  /// - Returns: The average color in sRGB, or `nil` if the region is empty.
  public static func averageColor(in image: CGImage, in rect: CGRect) -> SampledColor? {
    let clamped = rect.standardized.intersection(
      CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    guard clamped.width > 0, clamped.height > 0, image.width > 0, image.height > 0 else {
      return nil
    }

    let scale = min(
      1,
      Double(Self.averageSampleDimension) / Double(max(clamped.width, clamped.height))
    )
    let outputWidth = max(1, Int((clamped.width * scale).rounded(.up)))
    let outputHeight = max(1, Int((clamped.height * scale).rounded(.up)))

    guard let pixels = drawRegion(image, in: clamped, outputWidth: outputWidth, outputHeight: outputHeight) else {
      return nil
    }

    let sampleCount = outputWidth * outputHeight
    guard sampleCount > 0 else { return nil }

    var totalRed = 0
    var totalGreen = 0
    var totalBlue = 0
    var totalAlpha = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      totalRed += Int(pixels[index])
      totalGreen += Int(pixels[index + 1])
      totalBlue += Int(pixels[index + 2])
      totalAlpha += Int(pixels[index + 3])
    }
    return SampledColor(
      red: UInt8(totalRed / sampleCount),
      green: UInt8(totalGreen / sampleCount),
      blue: UInt8(totalBlue / sampleCount),
      alpha: UInt8(totalAlpha / sampleCount)
    )
  }

  /// Returns up to `count` dominant colors in a region, ordered by coverage
  /// (most frequent first).
  ///
  /// The region is downsampled, then each pixel's color is quantized to
  /// 5 bits per channel (32 levels) and tallied into buckets. The buckets
  /// with the largest populations become the result.
  ///
  /// - Parameters:
  ///   - image: The source image.
  ///   - rect: A rectangle in image space (top-left origin). Clamped to bounds.
  ///   - count: The maximum number of colors to return (1...16).
  /// - Returns: Dominant colors in sRGB, ordered by descending coverage.
  public static func dominantColors(in image: CGImage, in rect: CGRect, count: Int) -> [SampledColor] {
    let requested = min(max(count, 1), 16)
    let clamped = rect.standardized.intersection(
      CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    guard clamped.width > 0, clamped.height > 0, image.width > 0, image.height > 0 else {
      return []
    }

    let scale = min(
      1,
      Double(Self.dominantSampleDimension) / Double(max(clamped.width, clamped.height))
    )
    let outputWidth = max(1, Int((clamped.width * scale).rounded(.up)))
    let outputHeight = max(1, Int((clamped.height * scale).rounded(.up)))

    guard let pixels = drawRegion(image, in: clamped, outputWidth: outputWidth, outputHeight: outputHeight) else {
      return []
    }

    // Bucket by 5-bit quantized channels. The 15-bit key collapses all
    // sampled pixels into a bounded set of representative colors.
    var buckets: [UInt32: Int] = [:]
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let red = UInt32(pixels[index]) >> 3
      let green = UInt32(pixels[index + 1]) >> 3
      let blue = UInt32(pixels[index + 2]) >> 3
      let key = (red << 10) | (green << 5) | blue
      buckets[key, default: 0] += 1
    }

    return
      buckets
      .sorted { $0.value > $1.value }
      .prefix(requested)
      .map { key, _ in
        SampledColor(
          red: UInt8((key >> 10 & 0x1F) << 3),
          green: UInt8((key >> 5 & 0x1F) << 3),
          blue: UInt8((key & 0x1F) << 3),
          alpha: 255
        )
      }
  }

  /// Formats red, green, and blue components as a `#RRGGBB` hex string.
  public static func hexString(red: UInt8, green: UInt8, blue: UInt8) -> String {
    String(format: "#%02X%02X%02X", red, green, blue)
  }

  /// Draws a source region into a small sRGB bitmap buffer and returns the
  /// raw 8-bit RGBA bytes (premultiplied-last layout).
  ///
  /// - Parameters:
  ///   - image: The source image.
  ///   - rect: The source region in image space (top-left origin).
  ///   - outputWidth: Target buffer width in pixels.
  ///   - outputHeight: Target buffer height in pixels.
  /// - Returns: The RGBA bytes, or `nil` if the draw fails.
  private static func drawRegion(
    _ image: CGImage,
    in rect: CGRect,
    outputWidth: Int,
    outputHeight: Int
  ) -> [UInt8]? {
    let width = max(1, outputWidth)
    let height = max(1, outputHeight)
    guard let sourceCrop = image.cropping(to: rect) else { return nil }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let baseAddress = bytes.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.interpolationQuality = .none
      context.draw(sourceCrop, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return didDraw ? pixels : nil
  }
}
