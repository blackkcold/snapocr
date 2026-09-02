import CoreGraphics
import Foundation
import Testing

@testable import SharedKit

private enum TestImageFactory {
  static func solidImage(
    width: Int,
    height: Int,
    red: UInt8,
    green: UInt8,
    blue: UInt8
  ) -> CGImage? {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = red
      pixels[index + 1] = green
      pixels[index + 2] = blue
      pixels[index + 3] = 255
    }
    return makeImage(from: &pixels, width: width, height: height)
  }

  static func makeImage(
    from pixels: inout [UInt8],
    width: Int,
    height: Int
  ) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }
    return context.makeImage()
  }
}

struct ColorSamplerTests {
  @Test func pixelColorReadsSinglePixel() throws {
    let image = try #require(
      TestImageFactory.solidImage(width: 4, height: 4, red: 255, green: 0, blue: 128)
    )
    let color = ColorSampler.pixelColor(in: image, at: CGPoint(x: 2, y: 2))
    #expect(color != nil)
    #expect(color?.red == 255)
    #expect(color?.green == 0)
    #expect(color?.blue == 128)
    #expect(color?.alpha == 255)
  }

  @Test func pixelColorClampsOutOfRangeCoordinates() throws {
    let image = try #require(
      TestImageFactory.solidImage(width: 3, height: 3, red: 10, green: 20, blue: 30)
    )
    let bottomRight = ColorSampler.pixelColor(in: image, at: CGPoint(x: 999, y: 999))
    let topLeft = ColorSampler.pixelColor(in: image, at: CGPoint(x: -5, y: -5))
    #expect(bottomRight?.blue == 30)
    #expect(topLeft?.red == 10)
  }

  @Test func averageColorOverUniformRegionMatchesFill() throws {
    let image = try #require(
      TestImageFactory.solidImage(width: 8, height: 8, red: 70, green: 140, blue: 210)
    )
    let average = ColorSampler.averageColor(
      in: image,
      in: CGRect(x: 0, y: 0, width: 8, height: 8)
    )
    #expect(average != nil)
    #expect(average?.red == 70)
    #expect(average?.green == 140)
    #expect(average?.blue == 210)
  }

  @Test func dominantColorsReturnsMostFrequentColorFirst() throws {
    var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
    for y in 0..<8 {
      for x in 0..<8 {
        let index = (y * 8 + x) * 4
        if x < 4 {
          pixels[index] = 200
          pixels[index + 1] = 0
          pixels[index + 2] = 0
        } else {
          pixels[index] = 0
          pixels[index + 1] = 0
          pixels[index + 2] = 200
        }
        pixels[index + 3] = 255
      }
    }
    let image = try #require(TestImageFactory.makeImage(from: &pixels, width: 8, height: 8))

    let colors = ColorSampler.dominantColors(
      in: image,
      in: CGRect(x: 0, y: 0, width: 8, height: 8),
      count: 2
    )
    #expect(colors.count == 2)
    #expect(colors.map(\.hexString).contains("#C80000"))
    #expect(colors.map(\.hexString).contains("#0000C8"))
  }

  @Test func hexStringFormatsUppercase() {
    #expect(ColorSampler.hexString(red: 0, green: 128, blue: 255) == "#0080FF")
    #expect(ColorSampler.hexString(red: 255, green: 255, blue: 255) == "#FFFFFF")
    #expect(ColorSampler.hexString(red: 0, green: 0, blue: 0) == "#000000")
  }

  @Test func rgbStringFormatsDecimal() {
    let color = SampledColor(red: 255, green: 128, blue: 0, alpha: 255)
    #expect(color.rgbString == "rgb(255, 128, 0)")
    #expect(SampledColor(red: 0, green: 0, blue: 0, alpha: 255).rgbString == "rgb(0, 0, 0)")
    #expect(SampledColor(red: 16, green: 32, blue: 64, alpha: 255).rgbString == "rgb(16, 32, 64)")
  }

  @Test func sampledColorCodableRoundTrip() throws {
    let color = SampledColor(red: 255, green: 128, blue: 0, alpha: 255)
    let data = try JSONEncoder().encode(color)
    let decoded = try JSONDecoder().decode(SampledColor.self, from: data)
    #expect(decoded == color)
  }

  @Test func averageColorClampsEmptyOrOutOfBoundsRect() throws {
    let image = try #require(
      TestImageFactory.solidImage(width: 4, height: 4, red: 1, green: 2, blue: 3)
    )
    let outOfBounds = ColorSampler.averageColor(
      in: image,
      in: CGRect(x: 100, y: 100, width: 4, height: 4)
    )
    #expect(outOfBounds == nil)
  }
}
