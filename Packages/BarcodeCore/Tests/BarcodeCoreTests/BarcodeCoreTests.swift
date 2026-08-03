import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing

@testable import BarcodeCore

struct BarcodeCoreTests {
    @Test func detectsGeneratedQRCode() async throws {
        let image = try makeQRCode(payload: "https://snapglass.example/test")

        let results = try await VisionBarcodeEngine().detect(in: image, types: [.qr])

        let result = try #require(results.first)
        #expect(result.payload == "https://snapglass.example/test")
        #expect(result.type == .qr)
        #expect(result.confidence >= VisionBarcodeEngine.defaultMinimumConfidence)
    }

    @Test func requestedSymbologyFiltersQRCode() async throws {
        let image = try makeQRCode(payload: "filtered")

        let results = try await VisionBarcodeEngine().detect(in: image, types: [.ean13])

        #expect(results.isEmpty)
    }

    @Test func supportedSymbologiesMatchPublicBarcodeTypes() {
        let supported = VisionBarcodeEngine().supportedSymbologies()

        #expect(Set(supported.map(\.rawValue)) == Set(BarcodeType.allCases.map(\.rawValue)))
    }

    @Test func resultRoundTripsThroughCodable() throws {
        let original = BarcodeResult(
            payload: "payload",
            type: .code128,
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            confidence: 0.9
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BarcodeResult.self, from: data)

        #expect(decoded.payload == original.payload)
        #expect(decoded.type == original.type)
        #expect(decoded.boundingBox == original.boundingBox)
        #expect(decoded.confidence == original.confidence)
    }

    @Test func singleCopyCandidateRequiresExactlyOneNonEmptyPayload() {
        let first = BarcodeResult(
            payload: "https://snapglass.example/copy",
            type: .qr,
            boundingBox: .zero,
            confidence: 0.9
        )
        let second = BarcodeResult(
            payload: "second",
            type: .code128,
            boundingBox: .zero,
            confidence: 0.8
        )
        let empty = BarcodeResult(
            payload: "  \n",
            type: .qr,
            boundingBox: .zero,
            confidence: 0.9
        )

        #expect(BarcodeCopyCandidate.singlePayload(from: []) == nil)
        #expect(BarcodeCopyCandidate.singlePayload(from: [first]) == first.payload)
        #expect(BarcodeCopyCandidate.singlePayload(from: [first, second]) == nil)
        #expect(BarcodeCopyCandidate.singlePayload(from: [empty]) == nil)
    }

    private func makeQRCode(payload: String) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        let output = try #require(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        return try #require(context.createCGImage(output, from: output.extent))
    }
}
