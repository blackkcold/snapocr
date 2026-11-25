import CoreGraphics
import Foundation
import SharedKit
import Vision

/// A barcode detection engine backed by Apple Vision framework.
///
/// Uses `VNDetectBarcodesRequest` to detect and decode barcodes from images.
/// Supports QR, Code128, Code39, EAN-8/13, PDF417, Aztec, and DataMatrix symbologies.
///
/// Results are filtered by a minimum confidence threshold (default `0.3`)
/// and sorted by descending confidence when multiple barcodes are found.
///
/// ## Concurrency
///
/// This engine is fully `Sendable` and safe to use from any concurrency context.
/// Each `detect` call creates independent Vision request objects, so there is
/// no shared mutable state between calls.
///
/// ## Usage
///
/// ```swift
/// let engine = VisionBarcodeEngine()
/// let results = try await engine.detect(in: image, types: [.qr, .ean13])
/// ```
public final class VisionBarcodeEngine: BarcodeProtocol, Sendable {
    /// Default minimum confidence threshold for barcode results.
    public static let defaultMinimumConfidence: Float = 0.3

    private let logger: Logger
    private let minimumConfidence: Float

    /// Creates a Vision-based barcode detection engine.
    ///
    /// - Parameter minimumConfidence: The minimum confidence score (0.0–1.0)
    ///   for results to be included. Defaults to `0.3`.
    public init(minimumConfidence: Float = 0.3) {
        self.logger = Logger(category: "barcode")
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
    }

    // MARK: - BarcodeProtocol

    /// Detects and decodes barcodes in `image`.
    ///
    /// Every observation whose confidence passes the engine's threshold is returned,
    /// strongest first. An empty `types` array asks Vision for all mapped symbologies;
    /// otherwise only the requested types are scanned. Observations without a payload
    /// or with a symbology outside ``BarcodeType`` are skipped, and when every
    /// observation falls below the threshold the result is an empty array rather than
    /// an error.
    ///
    /// - Parameters:
    ///   - image: The image to scan.
    ///   - types: Symbologies to detect, or an empty array for all supported types.
    /// - Returns: Decoded barcodes sorted by descending confidence.
    /// - Throws: ``BarcodeError/detectionFailed(reason:)`` when Vision cannot perform
    ///   the request.
    public func detect(in image: CGImage, types: [BarcodeType]) async throws -> [BarcodeResult] {
        let symbologies = resolveSymbologies(from: types)

        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let start = Date()

        do {
            try handler.perform([request])
        } catch {
            logger.error("Barcode detection failed", error: error)
            throw BarcodeError.detectionFailed(reason: error.localizedDescription)
        }

        let processingTimeMs = start.distance(to: Date()) * 1000
        logger.metric("barcode.detection", value: processingTimeMs)

        guard let observations = request.results, !observations.isEmpty else {
            logger.info("No barcodes found in image")
            return []
        }

        let results =
            observations
            .filter { $0.confidence >= minimumConfidence }
            .compactMap { observation -> BarcodeResult? in
                guard let payload = observation.payloadStringValue,
                    let type = Self.mapToBarcodeType(observation.symbology)
                else {
                    return nil
                }
                return BarcodeResult(
                    payload: payload,
                    type: type,
                    boundingBox: observation.boundingBox,
                    confidence: observation.confidence
                )
            }
            .sorted { $0.confidence > $1.confidence }

        logger.info("Detected \(results.count) barcode(s)")

        if results.isEmpty, !observations.isEmpty {
            logger.warning(
                "All \(observations.count) observation(s) fell below confidence threshold \(minimumConfidence)"
            )
        }

        return results
    }

    /// Returns the highest-confidence barcode, or `nil` when none passes the threshold.
    ///
    /// This is a convenience wrapper around ``detect(in:types:)``; detection errors
    /// still propagate.
    ///
    /// - Parameters:
    ///   - image: The image to scan.
    ///   - types: Symbologies to detect, or an empty array for all supported types.
    /// - Returns: The strongest result, if any.
    /// - Throws: ``BarcodeError/detectionFailed(reason:)`` when Vision cannot perform
    ///   the request.
    public func detectSingle(in image: CGImage, types: [BarcodeType]) async throws -> BarcodeResult? {
        let results = try await detect(in: image, types: types)
        return results.first
    }

    /// Every ``BarcodeType`` case, in declaration order.
    ///
    /// The engine maps each case to its Vision symbology, so this list matches what
    /// ``detect(in:types:)`` can return.
    public func supportedSymbologies() -> [BarcodeType] {
        BarcodeType.allCases
    }

    // MARK: - Symbology Mapping

    /// All Vision symbologies that map to a known `BarcodeType`.
    private static let allSupportedSymbologies: [VNBarcodeSymbology] = {
        BarcodeType.allCases.compactMap { type in
            switch type {
            case .qr: return .qr
            case .code128: return .code128
            case .code39: return .code39
            case .ean8: return .ean8
            case .ean13: return .ean13
            case .pdf417: return .pdf417
            case .aztec: return .aztec
            case .dataMatrix: return .dataMatrix
            }
        }
    }()

    /// Maps `BarcodeType` to the corresponding Vision framework symbology.
    private static func mapToSymbology(_ type: BarcodeType) -> VNBarcodeSymbology? {
        switch type {
        case .qr: return .qr
        case .code128: return .code128
        case .code39: return .code39
        case .ean8: return .ean8
        case .ean13: return .ean13
        case .pdf417: return .pdf417
        case .aztec: return .aztec
        case .dataMatrix: return .dataMatrix
        }
    }

    /// Maps a Vision framework symbology to `BarcodeType`, or `nil` if
    /// the symbology is not in our supported set.
    private static func mapToBarcodeType(_ symbology: VNBarcodeSymbology) -> BarcodeType? {
        switch symbology {
        case .qr: return .qr
        case .code128: return .code128
        case .code39: return .code39
        case .ean8: return .ean8
        case .ean13: return .ean13
        case .pdf417: return .pdf417
        case .aztec: return .aztec
        case .dataMatrix: return .dataMatrix
        default: return nil
        }
    }

    /// Resolves the list of Vision symbologies to detect.
    ///
    /// If `types` is empty, all supported symbologies are used.
    /// Otherwise only the specified types are included, with unsupported
    /// types silently skipped.
    private func resolveSymbologies(from types: [BarcodeType]) -> [VNBarcodeSymbology] {
        if types.isEmpty {
            return Self.allSupportedSymbologies
        }
        return types.compactMap { Self.mapToSymbology($0) }
    }
}
