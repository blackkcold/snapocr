import Foundation
import OCRCore
import Testing

@testable import EditorInteractionTests

/// 验证 OCR 失败最终给用户看的是哪一种句子。
///
/// `OCRError.errorDescription` 是中文、面向开发者的。界面若直接拼接它，英/日/韩
/// 界面会在截图流程中途弹中文，并且说不清该怎么办。这些用例注入 `localize`，
/// 因此断言的是「选了哪一条文案」，与测试宿主的语言包无关。
struct OCRErrorPresentationTests {
    /// 每条失败都必须走到自己那条文案。
    @Test func everyFailureKindSelectsItsOwnSentence() {
        let localize = Self.markingLocalizer

        #expect(
            OCRErrorPresentation.message(for: OCRError.noTextFound, localize: localize)
                == "[No text found]"
        )
        #expect(
            OCRErrorPresentation.message(
                for: OCRError.visionRequestTimedOut(timeout: .seconds(30)),
                localize: localize
            ) == "[Text recognition timed out. Try again with a smaller area.]"
        )
        #expect(
            OCRErrorPresentation.message(for: OCRError.engineUnresponsive, localize: localize)
                == "[Text recognition stopped responding. Restart SnapGlass and try again.]"
        )
        #expect(
            OCRErrorPresentation.message(
                for: OCRError.engineUnavailable(.tesseract(languageDataPath: nil)),
                localize: localize
            ) == "[The selected text recognition engine is unavailable.]"
        )
        #expect(
            OCRErrorPresentation.message(
                for: OCRError.languageNotSupported("Tesseract 语言包 'chi_sim' 未安装"),
                localize: localize
            ) == "[The language pack for text recognition is not installed. Download it in Settings.]"
        )
        #expect(
            OCRErrorPresentation.message(
                for: OCRError.imageTooLarge(width: 99_999, height: 99_999),
                localize: localize
            ) == "[The image is too large to recognize. Try a smaller area.]"
        )
        #expect(
            OCRErrorPresentation.message(
                for: OCRError.recognitionFailed(reason: "Vision 框架识别失败: injected"),
                localize: localize
            ) == "[Text recognition failed. Try again.]"
        )
    }

    /// 关键回归：任何失败都不得把引擎的中文描述带进界面。
    ///
    /// 这条用例覆盖 `OCRError` 的**每一个** case。之前的实现给「其余失败」留了一条
    /// `String(format: localize("OCR failed: %@"), error.localizedDescription)` 的
    /// 兜底路径，于是 `recognitionFailed` / `languageNotSupported` / `imageTooLarge`
    /// 在英/日/韩界面依旧弹中文，而旧测试恰好把这一行为断言成了正确。现在没有兜底
    /// 拼接，新增 case 也必须显式给出文案，否则这里会红。
    @Test func noEngineDescriptionEverReachesTheUser() {
        let localize = Self.markingLocalizer
        let failures: [OCRError] = [
            .noTextFound,
            .visionRequestTimedOut(timeout: .seconds(30)),
            .engineUnresponsive,
            .engineUnavailable(.vision),
            .engineUnavailable(.tesseract(languageDataPath: nil)),
            .languageNotSupported("Tesseract 语言包 'chi_sim' 未安装。请使用 LanguagePackDownloader 下载"),
            .imageTooLarge(width: 99_999, height: 99_999),
            .recognitionFailed(reason: "Vision 框架识别失败: injected"),
            .confidenceTooLow(actual: 0.2, threshold: 0.9),
        ]

        for failure in failures {
            let message = OCRErrorPresentation.message(for: failure, localize: localize)
            #expect(!message.isEmpty, "every failure must produce a sentence")
            // 开发中文的关键词；命中任何一个都说明兜底拼接又回来了。
            for leaked in ["文字识别", "识别失败", "语言包", "图片尺寸过大", "置信度", "Vision 框架"] {
                #expect(
                    !message.contains(leaked),
                    "the developer description leaked into the toast for \(failure): \(message)"
                )
            }
            // 译文里不该出现原始 reason；注入的 localizer 会把 key 包成 [key]。
            #expect(
                message.hasPrefix("["),
                "the sentence must come from the localization table, not from the error: \(message)"
            )
        }
    }

    /// 不是 `OCRError` 的失败也要给出一句可操作的文案，不能是原始描述。
    @Test func aForeignErrorGetsTheGenericSentence() {
        struct Foreign: Error, LocalizedError {
            var errorDescription: String? { "boom from somewhere else" }
        }

        let message = OCRErrorPresentation.message(for: Foreign(), localize: Self.markingLocalizer)
        #expect(message == "[Text recognition failed. Try again.]")
        #expect(!message.contains("boom"))
    }

    /// 诊断信息仍完整保留给日志，只是不进界面。
    @Test func theDiagnosticKeepsTheEngineDetail() {
        let failure = OCRError.recognitionFailed(reason: "Vision 框架识别失败: injected")
        #expect(OCRErrorPresentation.diagnostic(for: failure).contains("Vision 框架识别失败: injected"))
    }

    /// 分类本身要正确：它决定了文案，也决定调用方是否需要提示重启。
    ///
    /// `kind(of:)` 不再返回 Optional：拿不准的失败归到 `.unknown`，而不是让调用方
    /// 以为「这不是 OCR 错误」再去拼接原始描述。
    @Test func kindsAreClassifiedStructurally() {
        #expect(OCRErrorPresentation.kind(of: OCRError.noTextFound) == .noText)
        #expect(
            OCRErrorPresentation.kind(of: OCRError.visionRequestTimedOut(timeout: .seconds(30)))
                == .timedOut
        )
        #expect(OCRErrorPresentation.kind(of: OCRError.engineUnresponsive) == .engineUnresponsive)
        #expect(
            OCRErrorPresentation.kind(of: OCRError.engineUnavailable(.vision)) == .engineUnavailable
        )
        #expect(
            OCRErrorPresentation.kind(of: OCRError.languageNotSupported("chi_sim"))
                == .languageNotInstalled
        )
        #expect(
            OCRErrorPresentation.kind(of: OCRError.imageTooLarge(width: 12, height: 34))
                == .imageTooLarge(width: 12, height: 34)
        )
        #expect(
            OCRErrorPresentation.kind(of: OCRError.recognitionFailed(reason: "x"))
                == .recognitionFailed
        )
        #expect(
            OCRErrorPresentation.kind(of: OCRError.confidenceTooLow(actual: 0.1, threshold: 0.9))
                == .recognitionFailed
        )
        #expect(OCRErrorPresentation.kind(of: CancellationError()) == .unknown)
    }

    /// 每条文案在四个语言包里都存在（含新增的三条）。
    @Test func theNewSentencesExistInEveryLanguage() {
        let keys = [
            "Text recognition timed out. Try again with a smaller area.",
            "Text recognition stopped responding. Restart SnapGlass and try again.",
            "The selected text recognition engine is unavailable.",
            "The language pack for text recognition is not installed. Download it in Settings.",
            "The image is too large to recognize. Try a smaller area.",
            "Text recognition failed. Try again.",
        ]
        for language in ["en", "zh-Hans", "ja", "ko"] {
            let table = Self.contents(of: language)
            #expect(!table.isEmpty, "\(language) table could not be read")
            for key in keys {
                #expect(
                    table.contains("\"\(key)\""),
                    "\(language) is missing the sentence: \(key)"
                )
            }
        }
    }

    /// 已被逐条文案取代的兜底键不得残留：留着它，下一个人就会把它当模板再用一次。
    @Test func theGenericFallbackKeyIsGone() {
        for language in ["en", "zh-Hans", "ja", "ko"] {
            let table = Self.contents(of: language)
            #expect(
                !table.contains("\"OCR failed: %@\""),
                "\(language) still carries the removed generic key"
            )
        }
    }

    // MARK: - 辅助

    /// 把 key 包成 `[key]`，用来断言选了哪一条，而不用关心真实译文。
    private static func markingLocalizer(_ key: String) -> String {
        "[\(key)]"
    }

    /// 读取一个语言包的 `Localizable.strings`。
    ///
    /// 测试目标不加载 App bundle 的资源，因此直接按仓库相对路径读取；路径来自
    /// `#filePath`，与本文件在仓库中的位置绑定。
    private static func contents(of language: String) -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EditorTests
            .deletingLastPathComponent()  // SnapGlass
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // repository root
        let path =
            repositoryRoot
            .appendingPathComponent("App/SnapGlass/Resources")
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }
}
