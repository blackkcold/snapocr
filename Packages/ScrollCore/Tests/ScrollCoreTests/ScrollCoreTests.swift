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

    // MARK: - Wave 1B / B5: single-canvas stitching

    @Test func stitchActorReportsSingleCanvasAllocationAndOneProbePerPair() async throws {
        let frames = try scrolledFrames(count: 5, width: 80, height: 100, scroll: 60)
        let actor = ScrollStitchActor(
            overlapDetector: OverlapDetector(similarityThreshold: 0.99, searchStep: 2),
            budget: StitchBudget(maxPixels: 80 * 400, maxHeight: 400)
        )

        let result = try await actor.stitchFramesDetailed(frames.map { ScrollFrame(image: $0, index: 0) })

        #expect(result.image.height == 340)
        #expect(!result.isTruncated)
        #expect(result.stitchedFrameCount == 5)
        #expect(await actor.stitchCanvasAllocationCount == 1)
        #expect(await actor.stitchCanvasAllocatedBytes == 80 * 340 * 4)
        #expect(await actor.overlapProbeCount == 4)
    }

    @Test func stitchActorTruncatesAtPixelBudgetInsteadOfGrowingPastIt() async throws {
        let frames = try scrolledFrames(count: 4, width: 80, height: 100, scroll: 60)
        // 80 × 120 px budget: the third frame no longer fits.
        let actor = ScrollStitchActor(
            overlapDetector: OverlapDetector(similarityThreshold: 0.99, searchStep: 2),
            budget: StitchBudget(maxPixels: 80 * 120, maxHeight: 32_768)
        )

        let result = try await actor.stitchFramesDetailed(frames.map { ScrollFrame(image: $0, index: 0) })

        #expect(result.image.height == 120)
        #expect(result.isTruncated)
        #expect(result.stitchedFrameCount == 2)
        #expect(await actor.stitchCanvasAllocationCount == 1)
    }

    /// 判定基准是「同宽同高 + 探测成功」这一常见路径；帧高中途变化或探测失败时
    /// 新实现按上一帧高度收敛（旧实现按合成图高度），两者会有意不同。
    @Test func stitchActorMatchesLegacyPairwiseStitchPixelForPixel() async throws {
        let frames = try scrolledFrames(count: 4, width: 60, height: 90, scroll: 50)
        let detector = OverlapDetector(similarityThreshold: 0.99, searchStep: 2)
        let actor = ScrollStitchActor(overlapDetector: detector)

        let stitched = try await actor.stitchFrames(frames.map { ScrollFrame(image: $0, index: 0) })
        let reference = try legacyStitch(frames: frames, detector: detector)

        #expect(stitched.width == reference.width)
        #expect(stitched.height == reference.height)
        #expect(try rgbaBytes(stitched) == rgbaBytes(reference))
    }

    @Test func stitchActorKeepsLargeScrolledStitchInsideBudget() async throws {
        let frames = try scrolledFrames(count: 6, width: 800, height: 1200, scroll: 900)
        let actor = ScrollStitchActor(
            overlapDetector: OverlapDetector(similarityThreshold: 0.99, searchStep: 4)
        )

        let start = Date()
        let result = try await actor.stitchFramesDetailed(frames.map { ScrollFrame(image: $0, index: 0) })
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.image.width == 800)
        #expect(result.image.height == 1200 + 5 * 900)
        #expect(await actor.stitchCanvasAllocationCount == 1)
        #expect(await actor.stitchCanvasAllocatedBytes <= StitchBudget.default.maxPixels * 4)
        // Debug 构建下 SSIM 循环没有优化，且机器负载会明显影响结果；这里只挡
        // 「数量级回归」，真实门槛（release 0.03s / 增量路径 0.28s）记在台账里。
        #expect(elapsed < 30.0, "stitching took \(elapsed)s")
    }

    // MARK: - B5 incremental stitching

    @Test func incrementalStitchMatchesBatchStitchPixelForPixel() async throws {
        let images = try scrolledFrames(count: 4, width: 60, height: 90, scroll: 50)
        let detector = OverlapDetector(similarityThreshold: 0.99, searchStep: 2)
        let budget = StitchBudget(maxPixels: 1_000_000, maxHeight: 4096)

        let batch = ScrollStitchActor(overlapDetector: detector, budget: budget)
        let incremental = ScrollStitchActor(overlapDetector: detector, budget: budget)

        try await incremental.beginIncrementalStitch(firstFrame: ScrollFrame(image: images[0], index: 0))
        for image in images.dropFirst() {
            _ = try await incremental.appendIncrementalFrame(image)
        }
        let incrementalResult = try await incremental.finishIncrementalStitch()
        let batchResult = try await batch.stitchFramesDetailed(images.map { ScrollFrame(image: $0, index: 0) })

        #expect(incrementalResult.image.width == batchResult.image.width)
        #expect(incrementalResult.image.height == batchResult.image.height)
        #expect(try rgbaBytes(incrementalResult.image) == rgbaBytes(batchResult.image))
    }

    @Test func incrementalStitchStopsAtBudgetAndKeepsPartialImage() async throws {
        let images = try scrolledFrames(count: 4, width: 80, height: 100, scroll: 60)
        let actor = ScrollStitchActor(
            overlapDetector: OverlapDetector(similarityThreshold: 0.99, searchStep: 2),
            budget: StitchBudget(maxPixels: 80 * 160, maxHeight: 160)
        )

        try await actor.beginIncrementalStitch(firstFrame: ScrollFrame(image: images[0], index: 0))
        let second = try await actor.appendIncrementalFrame(images[1])
        let third = try await actor.appendIncrementalFrame(images[2])

        #expect(second == .appended(frameCount: 2))
        #expect(third == .limitReached)

        let result = try await actor.finishIncrementalStitch()
        #expect(result.image.height == 160)
        #expect(result.isTruncated)
        #expect(result.stitchedFrameCount == 2)
        #expect(await actor.stitchCanvasAllocationCount == 1)
        #expect(await actor.stitchCanvasAllocatedBytes == 80 * 160 * 4)
    }

    @Test func incrementalStitchRejectsDuplicateFrames() async throws {
        let images = try scrolledFrames(count: 2, width: 60, height: 90, scroll: 50)
        let actor = ScrollStitchActor(
            overlapDetector: OverlapDetector(similarityThreshold: 0.99, searchStep: 2),
            budget: StitchBudget(maxPixels: 1_000_000, maxHeight: 4096)
        )

        try await actor.beginIncrementalStitch(firstFrame: ScrollFrame(image: images[0], index: 0))
        let duplicate = try await actor.appendIncrementalFrame(images[0])
        let appended = try await actor.appendIncrementalFrame(images[1])

        #expect(duplicate == .duplicate)
        #expect(appended == .appended(frameCount: 2))
        #expect(await actor.overlapProbeCount == 1)
    }

    @Test func incrementalStitchStopsWhenFrameWidthChanges() async throws {
        let images = try scrolledFrames(count: 2, width: 60, height: 90, scroll: 50)
        let actor = ScrollStitchActor(
            overlapDetector: OverlapDetector(similarityThreshold: 0.99, searchStep: 2),
            budget: StitchBudget(maxPixels: 1_000_000, maxHeight: 4096)
        )

        try await actor.beginIncrementalStitch(firstFrame: ScrollFrame(image: images[0], index: 0))
        let wider = try makePatternedImage(width: 70, height: 90)
        let mismatch = try await actor.appendIncrementalFrame(wider)

        #expect(mismatch == .sizeChanged)
        let result = try await actor.finishIncrementalStitch()
        #expect(result.stitchedFrameCount == 1)
        #expect(result.isTruncated)
    }

    // MARK: - Fixtures

    /// Frames cut from one tall source image, scrolled down by `scroll` pixels each.
    private func scrolledFrames(count: Int, width: Int, height: Int, scroll: Int) throws -> [CGImage] {
        let sourceHeight = height + (count - 1) * scroll
        let source = try makePatternedImage(width: width, height: sourceHeight)
        return try (0..<count).map { index in
            try crop(source, y: index * scroll, height: height)
        }
    }

    /// The pre-B5 algorithm: stitch pair by pair into a fresh canvas each step.
    private func legacyStitch(frames: [CGImage], detector: OverlapDetector) throws -> CGImage {
        var composite = frames[0]
        for index in 0..<(frames.count - 1) {
            let imageA = composite
            let imageB = frames[index + 1]
            let heightA = CGFloat(imageA.height)
            let heightB = CGFloat(imageB.height)
            let width = CGFloat(max(imageA.width, imageB.width))

            let detected = detector.findBestMatchOffset(imageA, imageB)
            let offset = detected > 0 && detected < heightA ? detected : heightA * 0.85
            let totalHeight = offset + heightB

            let context = try #require(CGContext(
                data: nil,
                width: Int(width),
                height: Int(totalHeight),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let croppedA = try #require(imageA.cropping(to: CGRect(x: 0, y: 0, width: min(width, CGFloat(imageA.width)), height: offset)))
            context.draw(croppedA, in: CGRect(x: 0, y: heightB, width: CGFloat(croppedA.width), height: CGFloat(croppedA.height)))
            let drawHeightB = min(heightB, totalHeight - offset)
            let croppedB = try #require(imageB.cropping(to: CGRect(x: 0, y: Int(max(0, heightB - drawHeightB)), width: min(Int(width), imageB.width), height: Int(drawHeightB))))
            context.draw(croppedB, in: CGRect(x: 0, y: 0, width: CGFloat(croppedB.width), height: CGFloat(croppedB.height)))
            composite = try #require(context.makeImage())
        }
        return composite
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func crop(_ image: CGImage, y yOffset: Int, height: Int) throws -> CGImage {
        try #require(image.cropping(to: CGRect(x: 0, y: yOffset, width: image.width, height: height)))
    }

    private func makePatternedImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let value = (row * 73 + column * 37 + row * column * 11) % 256
                pixels[row * width + column] = UInt8(value)
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
