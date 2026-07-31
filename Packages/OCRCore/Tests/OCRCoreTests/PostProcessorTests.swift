import Testing
import Foundation
@testable import OCRCore

struct PostProcessorTests {

    private let processor = PostProcessor()

    // MARK: - detectURLs

    @Test func detectURLs_httpURL() {
        let urls = processor.detectURLs(in: "Visit https://example.com/path?q=1 for details")
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString == "https://example.com/path?q=1")
    }

    @Test func detectURLs_httpsURL() {
        let urls = processor.detectURLs(in: "Check out https://github.com/user/repo")
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString == "https://github.com/user/repo")
    }

    @Test func detectURLs_multipleURLs() {
        let urls = processor.detectURLs(in: "Site1: https://a.com, Site2: https://b.org/page")
        #expect(urls.count == 2)
    }

    @Test func detectURLs_noURL() {
        let urls = processor.detectURLs(in: "This text has no URLs at all")
        #expect(urls.isEmpty)
    }

    @Test func detectURLs_emptyString() {
        let urls = processor.detectURLs(in: "")
        #expect(urls.isEmpty)
    }

    @Test func detectURLs_urlWithPort() {
        let urls = processor.detectURLs(in: "Server: http://localhost:8080/api")
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString == "http://localhost:8080/api")
    }

    @Test func detectURLs_urlWithFragment() {
        let urls = processor.detectURLs(in: "See https://example.com/page#section")
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString == "https://example.com/page#section")
    }

    @Test func detectURLs_ftpURL() {
        let urls = processor.detectURLs(in: "FTP: ftp://files.example.com/data.zip")
        #expect(urls.count == 1)
        #expect(urls[0].scheme == "ftp")
    }

    @Test func detectURLs_embeddedInText() {
        let urls = processor.detectURLs(in: "The website https://example.com is great.")
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString == "https://example.com")
    }

    @Test func detectURLs_whitespaceOnly() {
        let urls = processor.detectURLs(in: "   \n  \t  ")
        #expect(urls.isEmpty)
    }

    // MARK: - process (passthrough)

    @Test func process_returnsSameResult() {
        let result = OCRResult(
            text: "Hello World",
            confidence: 0.95,
            engineType: .vision,
            layoutPreserved: true,
            observations: [],
            processingTimeMs: 100.0
        )
        let processed = processor.process(result)
        #expect(processed.text == result.text)
        #expect(processed.confidence == result.confidence)
    }

    @Test func editorBoundingBoxMatchesAppKitCanvasCoordinates() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        let line = OCRLine(text: "Example", confidence: 0.9, boundingBox: box)

        #expect(line.editorBoundingBox == box)
    }
}
