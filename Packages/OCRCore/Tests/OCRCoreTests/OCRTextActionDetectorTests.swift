import Foundation
import Testing

@testable import OCRCore

struct OCRTextActionDetectorTests {
    @Test func detectsALinkAndTrimsTrailingPunctuation() throws {
        let actions = OCRTextActionDetector.candidates(
            in: "Reference: https://example.com/path?q=1)."
        )

        let url = try #require(URL(string: "https://example.com/path?q=1"))
        #expect(actions.first == .openURL(url))
    }

    @Test func detectsAnEmailAddress() throws {
        let actions = OCRTextActionDetector.candidates(
            in: "Contact hello@snapglass.app for access."
        )

        #expect(actions.first == .composeEmail("hello@snapglass.app"))
    }

    @Test func detectsASixDigitCode() {
        let actions = OCRTextActionDetector.candidates(in: "验证码 481920，5 分钟内有效")

        #expect(actions.first == .copyCode("481920"))
    }

    @Test func ignoresDigitsEmbeddedInLongerNumbers() {
        let actions = OCRTextActionDetector.candidates(in: "订单号 123456789012")

        #expect(actions.isEmpty)
    }

    @Test func ordersLinkBeforeEmailBeforeCode() throws {
        let actions = OCRTextActionDetector.candidates(
            in: "https://example.com a@b.co 481920"
        )

        let url = try #require(URL(string: "https://example.com"))
        #expect(actions.count == 3)
        #expect(actions[0] == .openURL(url))
        #expect(actions[1] == .composeEmail("a@b.co"))
        #expect(actions[2] == .copyCode("481920"))
    }

    @Test func returnsNothingForPlainText() {
        #expect(OCRTextActionDetector.candidates(in: "just some words").isEmpty)
        #expect(OCRTextActionDetector.candidates(in: "").isEmpty)
    }

    @Test func removesDuplicateMatches() throws {
        let actions = OCRTextActionDetector.candidates(
            in: "https://example.com https://example.com"
        )

        #expect(actions.count == 1)
    }
}
