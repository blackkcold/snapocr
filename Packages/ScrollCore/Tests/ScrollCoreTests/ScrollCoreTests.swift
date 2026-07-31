import CoreGraphics
import Foundation
import Testing

@testable import ScrollCore

struct ScrollCoreTests {
    @Test func deduperRemovesIdenticalFramesAndKeepsScrolledFrame() throws {
        let source = try makePatternedImage(width: 80, height: 160)
        let first = try crop(source, y: 0, height: 100)
        let second = try crop(source, y: 60, height: 100)
        let frames = [
            ScrollFrame(image: first, index: 0),
            ScrollFrame(image: first, index: 1),
            ScrollFrame(image: second, index: 2),
        ]

        let deduped = FrameDeduper().deduplicate(frames)

        #expect(deduped.count == 2)
        #expect(deduped.map(\.index) == [0, 2])
    }

    @Test func overlapDetectorFindsExactScrollOffset() throws {
        let source = try makePatternedImage(width: 80, height: 160)
        let first = try crop(source, y: 0, height: 100)
        let second = try crop(source, y: 60, height: 100)
        let detector = OverlapDetector(similarityThreshold: 0.99, searchStep: 4)

        let offset = detector.findBestMatchOffset(first, second)
        let overlaps = detector.detectOverlaps([
            ScrollFrame(image: first, index: 0),
            ScrollFrame(image: second, index: 1),
        ])

        #expect(abs(offset - 60) <= 1)
        #expect(overlaps.count == 1)
        #expect(abs(overlaps[0] - 0.4) <= 0.01)
    }

    @Test func stitchActorReconstructsOverlappingFramesAtOriginalResolution() async throws {
        let source = try makePatternedImage(width: 80, height: 160)
        let first = try crop(source, y: 0, height: 100)
        let second = try crop(source, y: 60, height: 100)
        let actor = ScrollStitchActor(
            overlapDetector: OverlapDetector(similarityThreshold: 0.99, searchStep: 2)
        )

        let stitched = try await actor.stitchFrames([
            ScrollFrame(image: first, index: 0),
            ScrollFrame(image: second, index: 1),
        ])

        #expect(stitched.width == source.width)
        #expect(stitched.height == source.height)
        let similarity = FrameDeduper().computeFrameSimilarity(stitched, source)
        #expect(similarity > 0.99)
    }

    @Test func stitchActorRejectsInsufficientFrames() async throws {
        let image = try makePatternedImage(width: 32, height: 32)
        let actor = ScrollStitchActor()

        await #expect(throws: ScrollError.self) {
            _ = try await actor.stitchFrames([ScrollFrame(image: image, index: 0)])
        }
    }

    private func crop(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        try #require(image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)))
    }

    private func makePatternedImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = (y * 73 + x * 37 + y * x * 11) % 256
                pixels[y * width + x] = UInt8(value)
            }
        }

        let data = Data(pixels) as CFData
        let provider = try #require(CGDataProvider(data: data))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}
