import CoreGraphics
import Foundation

struct OCRTile: Sendable {
    let pixelRect: CGRect
}

enum TiledOCRProcessor {
    static func tiles(
        imageWidth: Int,
        imageHeight: Int,
        tileDimension: Int = MemoryGuard.tileDimension,
        overlap: Int = MemoryGuard.tileOverlap
    ) -> [OCRTile] {
        guard imageWidth > 0, imageHeight > 0, tileDimension > 0,
              overlap >= 0, overlap < tileDimension else {
            return []
        }

        let xOrigins = axisOrigins(length: imageWidth, tileLength: tileDimension, overlap: overlap)
        let yOrigins = axisOrigins(length: imageHeight, tileLength: tileDimension, overlap: overlap)
        return yOrigins.flatMap { y in
            xOrigins.map { x in
                OCRTile(pixelRect: CGRect(
                    x: x,
                    y: y,
                    width: min(tileDimension, imageWidth - x),
                    height: min(tileDimension, imageHeight - y)
                ))
            }
        }
    }

    static func remap(_ line: OCRLine, from tile: OCRTile, fullImageSize: CGSize) -> OCRLine {
        guard !line.boundingBox.isEmpty, fullImageSize.width > 0, fullImageSize.height > 0 else {
            return line
        }

        let tileRect = tile.pixelRect
        let box = line.boundingBox
        let mapped = CGRect(
            x: (tileRect.minX + box.minX * tileRect.width) / fullImageSize.width,
            y: (fullImageSize.height - tileRect.maxY + box.minY * tileRect.height)
                / fullImageSize.height,
            width: box.width * tileRect.width / fullImageSize.width,
            height: box.height * tileRect.height / fullImageSize.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        return OCRLine(
            text: line.text,
            confidence: line.confidence,
            boundingBox: mapped.isNull ? .zero : mapped
        )
    }

    static func merge(_ lines: [OCRLine], iouThreshold: CGFloat = 0.35) -> [OCRLine] {
        var kept: [OCRLine] = []
        for line in lines {
            let normalizedText = normalized(line.text)
            let duplicateIndex = kept.firstIndex { candidate in
                guard !line.boundingBox.isEmpty, !candidate.boundingBox.isEmpty,
                      normalized(candidate.text) == normalizedText else {
                    return false
                }
                return intersectionOverUnion(line.boundingBox, candidate.boundingBox) >= iouThreshold
                    || overlapRatio(line.boundingBox, candidate.boundingBox) >= 0.7
            }
            if let duplicateIndex {
                if line.confidence > kept[duplicateIndex].confidence {
                    kept[duplicateIndex] = line
                }
            } else {
                kept.append(line)
            }
        }
        return restoreReadingOrder(kept)
    }

    static func restoreReadingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        lines.enumerated().sorted { lhs, rhs in
            let left = lhs.element.boundingBox
            let right = rhs.element.boundingBox
            if left.isEmpty || right.isEmpty {
                if left.isEmpty == right.isEmpty { return lhs.offset < rhs.offset }
                return !left.isEmpty
            }

            let rowTolerance = max(left.height, right.height) * 0.5
            if abs(left.midY - right.midY) > rowTolerance {
                return left.midY > right.midY
            }
            if left.minX != right.minX {
                return left.minX < right.minX
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    private static func axisOrigins(length: Int, tileLength: Int, overlap: Int) -> [Int] {
        guard length > tileLength else { return [0] }
        let stride = tileLength - overlap
        var origins: [Int] = []
        var origin = 0
        while origin + tileLength < length {
            origins.append(origin)
            origin += stride
        }
        let finalOrigin = length - tileLength
        if origins.last != finalOrigin {
            origins.append(finalOrigin)
        }
        return origins
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return smallerArea > 0 ? intersectionArea / smallerArea : 0
    }
}
