import Testing
import Foundation
@testable import HistoryCore

struct TextAnonymizerTests {

    private let anonymizer = TextAnonymizer()

    // MARK: - anonymize: none level

    @Test func anonymize_none_returnsOriginal() {
        let result = anonymizer.anonymize("请联系 13812345678", level: .none)
        #expect(result == "请联系 13812345678")
    }

    // MARK: - anonymize: phone

    @Test func anonymize_phone_partial() {
        let result = anonymizer.anonymize("手机: 13812345678", level: .partial)
        #expect(result == "手机: 138****5678")
    }

    @Test func anonymize_phone_full() {
        let result = anonymizer.anonymize("手机: 13812345678", level: .full)
        #expect(result == "手机: ***")
    }

    // MARK: - anonymize: ID card

    @Test func anonymize_idCard_partial() {
        let result = anonymizer.anonymize("身份证: 110101199001011234", level: .partial)
        #expect(result == "身份证: 110101********1234")
    }

    @Test func anonymize_idCard_full() {
        let result = anonymizer.anonymize("身份证: 110101199001011234", level: .full)
        #expect(result == "身份证: ***")
    }

    // MARK: - anonymize: email

    @Test func anonymize_email_partial() {
        let result = anonymizer.anonymize("邮箱: user@example.com", level: .partial)
        #expect(result == "邮箱: u***@e***.com")
    }

    @Test func anonymize_email_full() {
        let result = anonymizer.anonymize("邮箱: user@example.com", level: .full)
        #expect(result == "邮箱: ***@***.***")
    }

    // MARK: - anonymize: bank card

    @Test func anonymize_bankCard_partial() {
        let result = anonymizer.anonymize("卡号: 6222021234567890", level: .partial)
        #expect(result == "卡号: ************7890")
    }

    @Test func anonymize_bankCard_full() {
        let result = anonymizer.anonymize("卡号: 6222021234567890", level: .full)
        #expect(result == "卡号: ***")
    }

    // MARK: - anonymize: landline

    @Test func anonymize_landline_partial() {
        let result = anonymizer.anonymize("电话: 010-12345678", level: .partial)
        #expect(result == "电话: 010-****5678")
    }

    @Test func anonymize_landline_full() {
        let result = anonymizer.anonymize("电话: 010-12345678", level: .full)
        #expect(result == "电话: ***")
    }

    // MARK: - anonymize: multiple patterns

    @Test func anonymize_multiplePatterns() {
        let text = "用户: 13812345678, 邮箱: test@example.com"
        let result = anonymizer.anonymize(text, level: .partial)
        #expect(result.contains("138****5678"))
        #expect(result.contains("t***@e***.com"))
    }

    @Test func anonymize_noSensitiveInfo() {
        let text = "这是一段普通文本，没有敏感信息。"
        let result = anonymizer.anonymize(text, level: .partial)
        #expect(result == text)
    }

    // MARK: - containsSensitiveInfo

    @Test func containsSensitiveInfo_phone() {
        #expect(anonymizer.containsSensitiveInfo("13812345678"))
    }

    @Test func containsSensitiveInfo_email() {
        #expect(anonymizer.containsSensitiveInfo("user@example.com"))
    }

    @Test func containsSensitiveInfo_noMatch() {
        #expect(!anonymizer.containsSensitiveInfo("普通文本"))
    }

    @Test func containsSensitiveInfo_empty() {
        #expect(!anonymizer.containsSensitiveInfo(""))
    }

    // MARK: - anonymizeEntries

    @Test func anonymizeEntries_partial() {
        let entry = HistoryEntry(textContent: "手机: 13812345678", ocrConfidence: 0.9, captureMode: "area")
        let entries = [entry]
        let result = anonymizer.anonymizeEntries(entries, level: .partial)
        #expect(result.count == 1)
        #expect(result[0].textContent.contains("138****5678"))
    }

    @Test func anonymizeEntries_none() {
        let entry = HistoryEntry(textContent: "手机: 13812345678", ocrConfidence: 0.9, captureMode: "area")
        let entries = [entry]
        let result = anonymizer.anonymizeEntries(entries, level: .none)
        #expect(result[0].textContent == "手机: 13812345678")
    }

    @Test func anonymizeEntries_removesPathsAndPreservesState() {
        let timestamp = Date(timeIntervalSince1970: 456)
        let entry = HistoryEntry(
            timestamp: timestamp,
            textContent: "user@example.com",
            ocrConfidence: 0.9,
            captureMode: "window",
            sourceAppName: "Mail user@example.com",
            sourceWindowTitle: "Contact 13812345678",
            imagePath: URL(fileURLWithPath: "/private/image.enc"),
            thumbnailPath: URL(fileURLWithPath: "/private/thumb.png"),
            isFavourite: true,
            tags: ["user@example.com"]
        )

        let result = anonymizer.anonymizeEntries([entry], level: .partial)[0]

        #expect(result.timestamp == timestamp)
        #expect(result.isFavourite)
        #expect(result.imagePath == nil)
        #expect(result.thumbnailPath == nil)
        #expect(result.sourceAppName == "Mail u***@e***.com")
        #expect(result.sourceWindowTitle == "Contact 138****5678")
        #expect(result.tags == ["u***@e***.com"])
    }
}
