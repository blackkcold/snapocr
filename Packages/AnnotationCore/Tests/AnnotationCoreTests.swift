import CoreGraphics
import Foundation
import Testing
@testable import AnnotationCore

struct AnnotationCoreTests {
    @Test func cropCanBeUndoneAndRedone() throws {
        let image = try makeImage(width: 200, height: 100)
        var document = AnnotationDocument(baseImage: image)
        document.addNode(AnnotationNode(
            tool: .rect,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        ))

        let crop = AnnotationNode(
            tool: .crop,
            normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        let interactor = AnnotationInteractor()
        try interactor.apply(.crop, to: &document, node: crop)

        #expect(document.baseImage.width == 100)
        #expect(document.baseImage.height == 50)
        #expect(document.nodes.isEmpty)

        try document.undo()
        #expect(document.baseImage.width == 200)
        #expect(document.baseImage.height == 100)
        #expect(document.nodes.count == 1)

        try document.redo()
        #expect(document.baseImage.width == 100)
        #expect(document.baseImage.height == 50)
        #expect(document.nodes.isEmpty)
    }

    @Test func exportPreservesOriginalResolution() throws {
        let image = try makeImage(width: 5_000, height: 20)
        let document = AnnotationDocument(baseImage: image)

        let rendered = try Renderer().render(document)

        #expect(rendered.width == 5_000)
        #expect(rendered.height == 20)
    }

    @Test func previewCanUseExplicitMaximumDimension() throws {
        let image = try makeImage(width: 200, height: 100)
        let document = AnnotationDocument(baseImage: image)

        let rendered = try Renderer().render(document, maximumDimension: 100)

        #expect(rendered.width == 100)
        #expect(rendered.height == 50)
    }

    @Test func nodeStyleCanBeUpdatedAndUndone() throws {
        let image = try makeImage(width: 200, height: 100)
        var document = AnnotationDocument(baseImage: image)
        var node = AnnotationNode(
            tool: .rect,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        )
        document.addNode(node)

        node.strokeStyle = .dashed
        node.cornerRadius = 12
        node.fillColor = CGColor(gray: 0, alpha: 0.5)
        document.updateNode(node)

        #expect(document.nodes[0].strokeStyle == .dashed)
        #expect(document.nodes[0].cornerRadius == 12)
        #expect(document.nodes[0].fillColor != nil)

        try document.undo()
        #expect(document.nodes[0].strokeStyle == .solid)
        #expect(document.nodes[0].cornerRadius == 0)
        #expect(document.nodes[0].fillColor == nil)
    }

    @Test func nodeLayerMovementCanBeUndone() throws {
        let image = try makeImage(width: 100, height: 100)
        var document = AnnotationDocument(baseImage: image)
        let first = AnnotationNode(tool: .rect, normalizedRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        let second = AnnotationNode(tool: .rect, normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        document.addNode(first)
        document.addNode(second)

        document.moveNode(by: first.id, offset: 1)
        #expect(document.nodes.map(\.id) == [second.id, first.id])

        try document.undo()
        #expect(document.nodes.map(\.id) == [first.id, second.id])
    }

    @Test func blurStyleCanBeUpdatedAndUndone() throws {
        let image = try makeImage(width: 120, height: 80)
        var document = AnnotationDocument(baseImage: image)
        var node = AnnotationNode(
            tool: .blur,
            blurMode: .gaussian,
            blurIntensity: 0.25,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        )
        document.addNode(node)

        node.blurMode = .mosaic
        node.blurIntensity = 0.9
        document.updateNode(node)

        #expect(document.nodes[0].blurMode == .mosaic)
        #expect(document.nodes[0].blurIntensity == 0.9)

        try document.undo()
        #expect(document.nodes[0].blurMode == .gaussian)
        #expect(document.nodes[0].blurIntensity == 0.25)
    }

    @Test func blurIntensityIsClamped() {
        let low = AnnotationNode(tool: .blur, blurIntensity: -1)
        let high = AnnotationNode(tool: .blur, blurIntensity: 2)

        #expect(low.blurIntensity == 0)
        #expect(high.blurIntensity == 1)
    }

    @Test func everyBlurModeRendersAtOriginalResolution() throws {
        let image = try makeCheckerboardImage(width: 96, height: 64)

        for mode in AnnotationBlurMode.allCases {
            var document = AnnotationDocument(baseImage: image)
            document.addNode(AnnotationNode(
                tool: .blur,
                blurMode: mode,
                blurIntensity: 0.7,
                normalizedRect: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.65)
            ))

            let rendered = try Renderer().render(document)
            #expect(rendered.width == image.width)
            #expect(rendered.height == image.height)
        }
    }

    @Test func textHorizontalScaleIsClamped() {
        let compressed = AnnotationNode(tool: .text, textHorizontalScale: 0)
        let stretched = AnnotationNode(tool: .text, textHorizontalScale: 20)

        #expect(compressed.textHorizontalScale == 0.1)
        #expect(stretched.textHorizontalScale == 10)
    }

    @Test func textSuggestedSizeTracksFontAndHorizontalScale() {
        let tool = TextTool()
        let regular = AnnotationNode(tool: .text, text: "SnapGlass", fontSize: 24)
        let stretched = AnnotationNode(
            tool: .text,
            text: "SnapGlass",
            fontSize: 24,
            textHorizontalScale: 2
        )
        let larger = AnnotationNode(tool: .text, text: "SnapGlass", fontSize: 48)

        let regularSize = tool.suggestedSize(for: regular)
        let stretchedSize = tool.suggestedSize(for: stretched)
        let largerSize = tool.suggestedSize(for: larger)

        #expect(stretchedSize.width - 8 > (regularSize.width - 8) * 1.9)
        #expect(abs(stretchedSize.height - regularSize.height) < 0.01)
        #expect(largerSize.width - 8 > (regularSize.width - 8) * 1.9)
        #expect(largerSize.height - 8 > (regularSize.height - 8) * 1.9)
    }

    @Test func textScaleUpdateCanBeUndoneAndRedone() throws {
        let image = try makeImage(width: 320, height: 180)
        var document = AnnotationDocument(baseImage: image)
        var node = AnnotationNode(
            tool: .text,
            text: "Resizable",
            fontSize: 20,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        )
        document.addNode(node)

        node.fontSize = 36
        node.textHorizontalScale = 1.75
        node.normalizedRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.3)
        document.updateNode(node)

        #expect(document.nodes[0].fontSize == 36)
        #expect(document.nodes[0].textHorizontalScale == 1.75)

        try document.undo()
        #expect(document.nodes[0].fontSize == 20)
        #expect(document.nodes[0].textHorizontalScale == 1)

        try document.redo()
        #expect(document.nodes[0].fontSize == 36)
        #expect(document.nodes[0].textHorizontalScale == 1.75)
    }

    @Test func horizontallyScaledTextRendersAtOriginalResolution() throws {
        let image = try makeImage(width: 320, height: 180)
        var document = AnnotationDocument(baseImage: image)
        document.addNode(AnnotationNode(
            tool: .text,
            text: "Scaled text",
            fontSize: 32,
            textHorizontalScale: 2.25,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.3)
        ))

        let rendered = try Renderer().render(document)

        #expect(rendered.width == image.width)
        #expect(rendered.height == image.height)
    }

    @Test func textIsVisibleInsideTightSuggestedBounds() throws {
        let image = try makeImage(width: 320, height: 180)
        let tool = TextTool()
        var node = AnnotationNode(
            tool: .text,
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            points: [CGPoint(x: 0.1, y: 0.2)],
            text: "Visible text",
            fontSize: 32
        )
        let suggestedSize = tool.suggestedSize(for: node)
        node.normalizedRect = CGRect(
            x: 0.1,
            y: 0.2,
            width: suggestedSize.width / CGFloat(image.width),
            height: suggestedSize.height / CGFloat(image.height)
        )

        var document = AnnotationDocument(baseImage: image)
        document.addNode(node)
        let rendered = try Renderer().render(document)
        let bytes = rendered.dataProvider?.data.flatMap { Data($0 as Data) } ?? Data()

        #expect(bytes.contains { $0 < 240 })
    }

    @Test func smallTextRemainsVisibleInsideTightBounds() throws {
        let image = try makeImage(width: 320, height: 180)
        let tool = TextTool()
        var node = AnnotationNode(
            tool: .text,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            points: [CGPoint(x: 0.1, y: 0.2)],
            text: "Small",
            fontSize: 10
        )
        let suggestedSize = tool.suggestedSize(for: node)
        node.normalizedRect = CGRect(
            x: 0.1,
            y: 0.2,
            width: suggestedSize.width / CGFloat(image.width),
            height: suggestedSize.height / CGFloat(image.height)
        )

        var document = AnnotationDocument(baseImage: image)
        document.addNode(node)
        let rendered = try Renderer().render(document)
        let bytes = rendered.dataProvider?.data.flatMap { Data($0 as Data) } ?? Data()

        #expect(bytes.contains { $0 < 240 })
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnnotationError.renderFailed(reason: "Unable to create test context")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw AnnotationError.renderFailed(reason: "Unable to create test image")
        }
        return image
    }

    private func makeCheckerboardImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnnotationError.renderFailed(reason: "Unable to create checkerboard context")
        }

        let cell = 8
        for y in stride(from: 0, to: height, by: cell) {
            for x in stride(from: 0, to: width, by: cell) {
                let isLight = ((x / cell) + (y / cell)).isMultiple(of: 2)
                context.setFillColor(CGColor(gray: isLight ? 0.9 : 0.1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        guard let image = context.makeImage() else {
            throw AnnotationError.renderFailed(reason: "Unable to create checkerboard image")
        }
        return image
    }
}
