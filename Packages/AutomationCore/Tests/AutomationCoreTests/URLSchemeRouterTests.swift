import Testing
import Foundation
@testable import AutomationCore

struct URLSchemeRouterTests {

    private let router = URLSchemeRouter()

    // MARK: - canHandle

    @Test func canHandle_snapglassScheme() {
        let url = URL(string: "snapglass://capture")!
        #expect(router.canHandle(url))
    }

    @Test func canHandle_otherScheme() {
        let url = URL(string: "https://example.com")!
        #expect(!router.canHandle(url))
    }

    @Test func canHandle_noScheme() {
        let url = URL(string: "capture")!
        #expect(!router.canHandle(url))
    }

    // MARK: - route: capture

    @Test func route_capture_defaultMode() throws {
        let url = URL(string: "snapglass://capture")!
        let result = try router.route(url)
        #expect(result.ocrAfterCapture == false)
        if case .capture(let mode, let output) = result.command {
            #expect(mode == nil)
            #expect(output == nil)
        } else {
            Issue.record("Expected .capture command")
        }
    }

    @Test func route_capture_withMode() throws {
        let url = URL(string: "snapglass://capture?mode=fullscreen")!
        let result = try router.route(url)
        if case .capture(let mode, _) = result.command {
            #expect(mode == "fullscreen")
        } else {
            Issue.record("Expected .capture command")
        }
    }

    @Test func route_capture_withOCR() throws {
        let url = URL(string: "snapglass://capture?mode=area&ocr=1")!
        let result = try router.route(url)
        #expect(result.ocrAfterCapture)
        if case .capture(let mode, _) = result.command {
            #expect(mode == "area")
        } else {
            Issue.record("Expected .capture command")
        }
    }

    @Test func route_capture_withOCR_true() throws {
        let url = URL(string: "snapglass://capture?mode=window&ocr=true")!
        let result = try router.route(url)
        #expect(result.ocrAfterCapture)
    }

    @Test func route_capture_withOutput() throws {
        let url = URL(string: "snapglass://capture?output=/tmp/test.png")!
        let result = try router.route(url)
        if case .capture(_, let output) = result.command {
            #expect(output == "/tmp/test.png")
        } else {
            Issue.record("Expected .capture command")
        }
    }

    // MARK: - route: ocr

    @Test func route_ocr_withFile() throws {
        let url = URL(string: "snapglass://ocr?file=/path/to/image.png")!
        let result = try router.route(url)
        if case .ocr(let file, let engine, let languages, _, _) = result.command {
            #expect(file == "/path/to/image.png")
            #expect(engine == nil)
            #expect(languages == nil)
        } else {
            Issue.record("Expected .ocr command")
        }
    }

    @Test func route_ocr_withEngine() throws {
        let url = URL(string: "snapglass://ocr?file=/path.png&engine=tesseract")!
        let result = try router.route(url)
        if case .ocr(_, let engine, _, _, _) = result.command {
            #expect(engine == "tesseract")
        } else {
            Issue.record("Expected .ocr command")
        }
    }

    @Test func route_ocr_withLanguages() throws {
        let url = URL(string: "snapglass://ocr?file=/path.png&languages=chi_sim,eng")!
        let result = try router.route(url)
        if case .ocr(_, _, let languages, _, _) = result.command {
            #expect(languages == ["chi_sim", "eng"])
        } else {
            Issue.record("Expected .ocr command")
        }
    }

    @Test func route_ocr_missingFile() {
        let url = URL(string: "snapglass://ocr")!
        expectAutomationError(.missingArgument, performing: { try router.route(url) })
    }

    @Test func route_ocr_emptyFile() {
        let url = URL(string: "snapglass://ocr?file=")!
        expectAutomationError(.missingArgument, performing: { try router.route(url) })
    }

    // MARK: - route: barcode

    @Test func route_barcode_withFile() throws {
        let url = URL(string: "snapglass://barcode?file=/path.png")!
        let result = try router.route(url)
        if case .barcode(let file, _, _) = result.command {
            #expect(file == "/path.png")
        } else {
            Issue.record("Expected .barcode command")
        }
    }

    @Test func route_barcode_withTypes() throws {
        let url = URL(string: "snapglass://barcode?file=/path.png&types=qr,code128")!
        let result = try router.route(url)
        if case .barcode(_, let types, _) = result.command {
            #expect(types == ["qr", "code128"])
        } else {
            Issue.record("Expected .barcode command")
        }
    }

    @Test func route_barcode_missingFile() {
        let url = URL(string: "snapglass://barcode")!
        expectAutomationError(.missingArgument, performing: { try router.route(url) })
    }

    // MARK: - route: errors

    @Test func route_unsupportedScheme() {
        let url = URL(string: "https://example.com")!
        expectAutomationError(.invalidCommand, performing: { try router.route(url) })
    }

    @Test func route_unknownHost() {
        let url = URL(string: "snapglass://unknown")!
        expectAutomationError(.invalidCommand, performing: { try router.route(url) })
    }

    @Test func route_emptyHost() {
        let url = URL(string: "snapglass://")!
        expectAutomationError(.invalidCommand, performing: { try router.route(url) })
    }

    private enum ExpectedAutomationError {
        case missingArgument
        case invalidCommand
    }

    private func expectAutomationError(_ expected: ExpectedAutomationError, performing operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected AutomationError")
        } catch let error as AutomationError {
            switch (expected, error) {
            case (.missingArgument, .missingArgument), (.invalidCommand, .invalidCommand):
                break
            default:
                Issue.record("Unexpected AutomationError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
