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

    @Test func payloadFormatterClassifiesSingleWebLink() throws {
        let payloads = BarcodePayloadFormatter.payloads(from: [
            makeResult("https://snapglass.example/a", type: .qr),
        ])

        let payload = try #require(payloads.first)
        #expect(payload.text == "https://snapglass.example/a")
        #expect(payload.type == .qr)
        #expect(payload.webLink == URL(string: "https://snapglass.example/a"))
    }

    @Test func payloadFormatterPreservesEngineOrder() {
        let payloads = BarcodePayloadFormatter.payloads(from: [
            makeResult("first", type: .code128),
            makeResult("second", type: .ean13),
        ])

        #expect(payloads.map(\.text) == ["first", "second"])
        #expect(payloads.map(\.type) == [.code128, .ean13])
    }

    @Test func payloadFormatterFiltersBlankAndDuplicatePayloads() {
        let payloads = BarcodePayloadFormatter.payloads(from: [
            makeResult("  repeated  ", type: .qr),
            makeResult("", type: .qr),
            makeResult("   \n ", type: .qr),
            makeResult("repeated", type: .qr),
        ])

        #expect(payloads.map(\.text) == ["repeated"])
    }

    @Test func payloadFormatterKeepsMultilinePayloadIntact() throws {
        let multiline = "line one\nline two"
        let joined = BarcodePayloadFormatter.joinedText(from: [
            makeResult(multiline, type: .qr),
        ])

        #expect(joined == multiline)
    }

    @Test func joinedTextJoinsEveryPayloadWithNewline() throws {
        let joined = try #require(
            BarcodePayloadFormatter.joinedText(from: [
                makeResult("a", type: .qr),
                makeResult("b", type: .code128),
            ])
        )

        #expect(joined == "a\nb")
    }

    @Test func joinedTextIsNilWhenNothingUsable() {
        #expect(BarcodePayloadFormatter.joinedText(from: []) == nil)
        #expect(BarcodePayloadFormatter.joinedText(from: [makeResult(" ", type: .qr)]) == nil)
    }

    @Test func payloadFormatterTreatsMailtoAsPlainText() throws {
        let payload = try #require(
            BarcodePayloadFormatter.payloads(from: [
                makeResult("mailto:someone@example.com", type: .qr),
            ]).first
        )

        #expect(payload.kind == .text)
        #expect(payload.webLink == nil)
    }

    @Test func payloadFormatterTreatsRelativeTextAsPlainText() {
        #expect(BarcodePayload.kind(of: "snapglass.example") == .text)

        guard case .webLink(let url) = BarcodePayload.kind(of: "https://snapglass.example/x") else {
            Issue.record("https URL should classify as webLink")
            return
        }
        #expect(url.host == "snapglass.example")
    }

    private func makeResult(_ payload: String, type: BarcodeType) -> BarcodeResult {
        BarcodeResult(
            payload: payload,
            type: type,
            boundingBox: .zero,
            confidence: 0.9
        )
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
