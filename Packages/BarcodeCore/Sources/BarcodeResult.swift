import CoreGraphics
import Foundation

/// Represents the result of a single barcode detection operation.
///
/// Contains the decoded payload string, the symbology type, spatial
/// location within the source image, and a confidence score.
///
/// This type is both `Sendable` and `Codable`, allowing it to be safely
/// passed across concurrency domains and serialized for storage or export.
///
/// - Note: The `boundingBox` uses normalized coordinates with the origin
///   at the bottom-left corner of the image. Each component is in the
///   range `[0.0, 1.0]`, relative to the image dimensions.
public struct BarcodeResult: Sendable, Codable {
    /// The decoded payload string of the barcode.
    ///
    /// For QR codes this is typically a URL or text; for EAN/Code128
    /// this is the numeric or alphanumeric identifier.
    public let payload: String

    /// The symbology type of the detected barcode.
    ///
    /// See ``BarcodeType`` for a list of supported symbologies.
    public let type: BarcodeType

    /// The bounding box of the barcode in normalized coordinates.
    ///
    /// - Origin: bottom-left corner of the image.
    /// - Range: each component in `[0.0, 1.0]` relative to the image dimensions.
    /// - Values are **not** scaled to image pixel dimensions.
    public let boundingBox: CGRect

    /// The confidence score of the recognition, in the range `[0.0, 1.0]`.
    ///
    /// Higher values indicate more reliable recognition. Values below
    /// `0.3` are generally considered unreliable.
    public let confidence: Float

    // MARK: - Initialization

    /// Creates a new barcode result.
    ///
    /// - Parameters:
    ///   - payload: The decoded payload string.
    ///   - type: The symbology type.
    ///   - boundingBox: The bounding box in normalized coordinates.
    ///   - confidence: The confidence score from `0.0` to `1.0`.
    public init(
        payload: String,
        type: BarcodeType,
        boundingBox: CGRect,
        confidence: Float
    ) {
        self.payload = payload
        self.type = type
        self.boundingBox = boundingBox
        self.confidence = confidence
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case payload
        case type
        case confidence
        case boxX
        case boxY
        case boxWidth
        case boxHeight
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payload, forKey: .payload)
        try container.encode(type.rawValue, forKey: .type)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(Double(boundingBox.origin.x), forKey: .boxX)
        try container.encode(Double(boundingBox.origin.y), forKey: .boxY)
        try container.encode(Double(boundingBox.size.width), forKey: .boxWidth)
        try container.encode(Double(boundingBox.size.height), forKey: .boxHeight)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payload = try container.decode(String.self, forKey: .payload)
        let typeRaw = try container.decode(String.self, forKey: .type)
        guard let decodedType = BarcodeType(rawValue: typeRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown BarcodeType raw value: \(typeRaw)"
            )
        }
        type = decodedType
        confidence = try container.decode(Float.self, forKey: .confidence)
        let x = try container.decode(Double.self, forKey: .boxX)
        let y = try container.decode(Double.self, forKey: .boxY)
        let width = try container.decode(Double.self, forKey: .boxWidth)
        let height = try container.decode(Double.self, forKey: .boxHeight)
        boundingBox = CGRect(x: x, y: y, width: width, height: height)
    }
}
