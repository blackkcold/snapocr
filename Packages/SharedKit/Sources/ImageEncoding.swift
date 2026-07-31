import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image file formats available for persisted captures.
public enum ImageFileFormat: String, CaseIterable, Sendable {
  /// Lossless Portable Network Graphics with alpha support.
  case png
  /// Lossy JPEG encoding for smaller opaque screenshots.
  case jpeg

  /// Filename extension without a leading dot.
  public var fileExtension: String { rawValue }

  fileprivate var typeIdentifier: CFString {
    switch self {
    case .png: UTType.png.identifier as CFString
    case .jpeg: UTType.jpeg.identifier as CFString
    }
  }
}

/// Shared ImageIO encoder used by editor and history persistence.
public enum ImageEncoder {
  /// Encodes a Core Graphics image in the requested format.
  public static func encode(
    _ image: CGImage,
    format: ImageFileFormat,
    jpegQuality: Double = PreferenceDefaults.captureJPEGQuality
  ) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        format.typeIdentifier,
        1,
        nil
      )
    else {
      throw AppError.internalError("无法创建图片编码器")
    }

    let properties: CFDictionary? =
      if format == .jpeg {
        [kCGImageDestinationLossyCompressionQuality: min(max(jpegQuality, 0), 1)] as CFDictionary
      } else {
        nil
      }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
      throw AppError.internalError("图片编码失败")
    }
    return data as Data
  }

  /// Atomically writes an encoded image to disk.
  public static func write(
    _ image: CGImage,
    to url: URL,
    format: ImageFileFormat,
    jpegQuality: Double = PreferenceDefaults.captureJPEGQuality
  ) throws {
    try encode(image, format: format, jpegQuality: jpegQuality).write(to: url, options: .atomic)
  }

  /// Returns whether the image's pixel format contains an alpha channel.
  public static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast:
      true
    case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly:
      image.alphaInfo == .alphaOnly
    @unknown default:
      false
    }
  }

  /// Efficiently samples the image to determine whether any visible transparency exists.
  public static func containsTransparency(_ image: CGImage, maximumSampleDimension: Int = 256) -> Bool {
    guard hasAlpha(image), image.width > 0, image.height > 0 else { return false }
    let scale = min(
      1,
      Double(maximumSampleDimension) / Double(max(image.width, image.height))
    )
    let width = max(1, Int((Double(image.width) * scale).rounded(.up)))
    let height = max(1, Int((Double(image.height) * scale).rounded(.up)))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let baseAddress = bytes.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else {
        return false
      }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard didDraw else { return false }

    return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
  }
}
