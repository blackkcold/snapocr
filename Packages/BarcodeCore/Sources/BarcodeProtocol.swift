import CoreGraphics
import Foundation

/// Supported barcode symbology types.
///
/// This enum covers the symbologies supported by the Apple Vision framework
/// barcode detector. New types may be added as Vision expands support.
public enum BarcodeType: String, Sendable, CaseIterable {
    /// QR Code (ISO/IEC 18004).
    case qr
    /// Code 128 (ISO/IEC 15417).
    case code128
    /// Code 39 (ISO/IEC 16388).
    case code39
    /// EAN-8 barcode.
    case ean8
    /// EAN-13 barcode (also covers UPC-A).
    case ean13
    /// PDF417 (ISO/IEC 15438).
    case pdf417
    /// Aztec Code (ISO/IEC 24778).
    case aztec
    /// Data Matrix (ISO/IEC 16022).
    case dataMatrix
}

/// A protocol defining the interface for barcode detection engines.
///
/// Conforming types implement barcode recognition using platform-specific
/// frameworks (e.g. Apple Vision on macOS/iOS). The protocol uses `CGImage`
/// as the common image input type, which can be created from most platform
/// image representations.
///
/// ## Concurrency
///
/// This protocol requires `Sendable` conformance. All methods are `async`
/// and designed to be called from any task context. Implementations must
/// not assume main-actor execution.
///
/// ## Usage
///
/// ```swift
/// let engine = VisionBarcodeEngine()
/// let results = try await engine.detect(in: image, types: [.qr, .code128])
/// for barcode in results {
///     print("Found \(barcode.type): \(barcode.payload)")
/// }
/// ```
public protocol BarcodeProtocol: Sendable {
    /// Detects barcodes of the specified types in an image.
    ///
    /// This method may return multiple results if the image contains
    /// more than one barcode. Results are sorted by confidence in
    /// descending order.
    ///
    /// - Parameters:
    ///   - image: The image to scan for barcodes.
    ///   - types: The symbology types to detect. Pass an empty array
    ///     to detect all supported types.
    /// - Returns: An array of ``BarcodeResult`` instances, one per
    ///   detected barcode, sorted by descending confidence.
    /// - Throws: ``BarcodeError`` if detection fails.
    func detect(in image: CGImage, types: [BarcodeType]) async throws -> [BarcodeResult]

    /// Detects a single barcode in an image.
    ///
    /// This is a convenience method that returns only the highest-confidence
    /// result. Equivalent to calling `detect(in:types:)` and returning the
    /// first element.
    ///
    /// - Parameters:
    ///   - image: The image to scan for barcodes.
    ///   - types: The symbology types to detect.
    /// - Returns: The highest-confidence ``BarcodeResult``, or `nil` if
    ///   no barcode was found.
    /// - Throws: ``BarcodeError`` if detection fails.
    func detectSingle(in image: CGImage, types: [BarcodeType]) async throws -> BarcodeResult?

    /// Returns the list of symbology types supported by this engine.
    ///
    /// - Returns: An array of ``BarcodeType`` values that this engine
    ///   can recognize.
    func supportedSymbologies() -> [BarcodeType]
}

/// Errors that can occur during barcode detection.
public enum BarcodeError: Error, Sendable {
    /// No barcode was found in the image.
    ///
    /// This error is thrown when detection completed successfully but
    /// no barcode matching the requested types was found.
    case noBarcodeFound

    /// The specified barcode type is not supported by this engine.
    ///
    /// - Parameter type: The unsupported ``BarcodeType``.
    case unsupportedType(BarcodeType)

    /// Barcode detection failed due to an underlying error.
    ///
    /// - Parameter reason: A description of the failure.
    case detectionFailed(reason: String)
}
