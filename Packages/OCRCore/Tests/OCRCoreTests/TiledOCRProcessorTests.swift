import CoreGraphics
import Testing

@testable import OCRCore

struct TiledOCRProcessorTests {
    @Test func memoryGuardChecksBothImageDimensions() throws {
        let withinLimit = try makeImage(width: 4096, height: 800)
        let tooWide = try makeImage(width: 4097, height: 800)
        let tooTall = try makeImage(width: 800, height: 4097)

        #expect(!MemoryGuard.requiresTiling(withinLimit))
        #expect(MemoryGuard.requiresTiling(tooWide))
        #expect(MemoryGuard.requiresTiling(tooTall))
    }

    @Test func tilesCoverWideImageWithOverlap() {
        let tiles = TiledOCRProcessor.tiles(imageWidth: 5000, imageHeight: 1000)

        #expect(tiles.count == 3)
        #expect(tiles.first?.pixelRect.minX == 0)
        #expect(tiles.last?.pixelRect.maxX == 5000)
        #expect(tiles.allSatisfy { $0.pixelRect.minY == 0 && $0.pixelRect.maxY == 1000 })
        #expect(
            tiles[0].pixelRect.intersection(tiles[1].pixelRect).width
                >= CGFloat(MemoryGuard.tileOverlap)
        )
    }

    @Test func tilesCoverTallImageWithOverlap() {
        let tiles = TiledOCRProcessor.tiles(imageWidth: 1000, imageHeight: 5000)

        #expect(tiles.count == 3)
        #expect(tiles.first?.pixelRect.minY == 0)
        #expect(tiles.last?.pixelRect.maxY == 5000)
        #expect(tiles.allSatisfy { $0.pixelRect.minX == 0 && $0.pixelRect.maxX == 1000 })
        #expect(
            tiles[0].pixelRect.intersection(tiles[1].pixelRect).height
                >= CGFloat(MemoryGuard.tileOverlap)
        )
    }

    @Test func tilesCreateTwoDimensionalGrid() {
        let tiles = TiledOCRProcessor.tiles(imageWidth: 5000, imageHeight: 5000)

        #expect(tiles.count == 9)
        #expect(tiles.contains { $0.pixelRect.origin == .zero })
        #expect(tiles.contains { $0.pixelRect.maxX == 5000 && $0.pixelRect.maxY == 5000 })
        #expect(tiles.allSatisfy {
            $0.pixelRect.minX >= 0 && $0.pixelRect.minY >= 0
                && $0.pixelRect.maxX <= 5000 && $0.pixelRect.maxY <= 5000
        })
    }

    @Test func remapConvertsTileLocalBoxToFullImageCoordinates() {
        let tile = OCRTile(pixelRect: CGRect(x: 2000, y: 1000, width: 2000, height: 2000))
        let line = OCRLine(
            text: "Mapped",
            confidence: 0.9,
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )

        let mapped = TiledOCRProcessor.remap(
            line,
            from: tile,
            fullImageSize: CGSize(width: 6000, height: 4000)
        )

        #expect(abs(mapped.boundingBox.minX - (2500.0 / 6000.0)) < 0.0001)
        #expect(abs(mapped.boundingBox.minY - 0.375) < 0.0001)
        #expect(abs(mapped.boundingBox.width - (1000.0 / 6000.0)) < 0.0001)
        #expect(abs(mapped.boundingBox.height - 0.25) < 0.0001)
    }

    @Test func remapPreservesPositionlessFallbackLines() {
        let line = OCRLine(text: "Fallback", confidence: 0.8, boundingBox: .zero)
        let mapped = TiledOCRProcessor.remap(
            line,
            from: OCRTile(pixelRect: CGRect(x: 100, y: 200, width: 500, height: 500)),
            fullImageSize: CGSize(width: 2000, height: 2000)
        )

        #expect(mapped.boundingBox == .zero)
    }

    @Test func mergeDeduplicatesOverlappingSameTextByConfidence() {
        let low = OCRLine(
            text: "Duplicate",
            confidence: 0.65,
            boundingBox: CGRect(x: 0.2, y: 0.7, width: 0.3, height: 0.08)
        )
        let high = OCRLine(
            text: "Duplicate",
            confidence: 0.95,
            boundingBox: CGRect(x: 0.21, y: 0.7, width: 0.3, height: 0.08)
        )

        let merged = TiledOCRProcessor.merge([low, high])

        #expect(merged.count == 1)
        #expect(merged[0].confidence == high.confidence)
    }

    @Test func mergePreservesSameTextAtDifferentLocations() {
        let first = OCRLine(
            text: "Repeated",
            confidence: 0.9,
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05)
        )
        let second = OCRLine(
            text: "Repeated",
            confidence: 0.85,
            boundingBox: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.05)
        )

        #expect(TiledOCRProcessor.merge([first, second]).count == 2)
    }

    @Test func mergePreservesPositionlessFallbackOrder() {
        let first = OCRLine(text: "First", confidence: 0.5, boundingBox: .zero)
        let second = OCRLine(text: "Second", confidence: 0.95, boundingBox: .zero)

        #expect(TiledOCRProcessor.merge([first, second]).map(\.text) == ["First", "Second"])
    }

    @Test func mergeRestoresTopToBottomAndLeftToRightOrder() {
        let bottom = OCRLine(
            text: "Bottom",
            confidence: 0.9,
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        )
        let topRight = OCRLine(
            text: "Top right",
            confidence: 0.9,
            boundingBox: CGRect(x: 0.6, y: 0.8, width: 0.2, height: 0.05)
        )
        let topLeft = OCRLine(
            text: "Top left",
            confidence: 0.9,
            boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05)
        )

        let merged = TiledOCRProcessor.merge([bottom, topRight, topLeft])

        #expect(merged.map(\.text) == ["Top left", "Top right", "Bottom"])
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let image = context.makeImage() else {
            throw OCRError.recognitionFailed(reason: "Unable to create test image")
        }
        return image
    }
}
