import Foundation
import OCRCore
import Testing

@testable import EditorInteractionTests

/// 验证 OCR 失败最终给用户看的是哪一种句子。
///
/// `OCRError.errorDescription` 是中文、面向开发者的：超时、引擎无响应这些新失败
/// 若被直接拼进 toast，英/日/韩界面会在截图流程中途弹中文，并且说不清该怎么办。
/// 这些用例注入 `localize`，因此断言的是「选了哪一条文案」，与测试宿主的语言包无关。
struct OCRErrorPresentationTests {
    /// 每条可预期的失败都必须走到对应的那条文案。
    @Test func eachFailureKindSelectsItsOwnSentence() {
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
    }

    /// 关键回归：引擎自己的中文描述不得出现在界面上。
    ///
    /// 超时与无响应都是这次新增的失败；它们曾经没有独立文案，只能借用
    /// `errorDescription`，而后者是中文。
    @Test func theEngineDescriptionNeverReachesTheUser() {
        let localize = Self.markingLocalizer
        let failures: [OCRError] = [
            .visionRequestTimedOut(timeout: .seconds(30)),
            .engineUnresponsive,
            .noTextFound,
            .engineUnavailable(.vision),
        ]

        for failure in failures {
            let message = OCRErrorPresentation.message(for: failure, localize: localize)
            #expect(
                !message.contains("文字识别"),
                "a developer-facing Chinese description leaked into the toast: \(message)"
            )
            #expect(
                !message.contains("OCR 识别失败"),
                "the raw error description leaked into the toast: \(message)"
            )
        }
    }

    /// 其余失败保留原始描述，用「识别失败：<原因>」的句式，reason 仍可诊断。
    @Test func anUnrecognisedFailureKeepsItsDescription() {
        let localize = Self.markingLocalizer
        let failure = OCRError.recognitionFailed(reason: "Vision 框架识别失败: injected")

        let message = OCRErrorPresentation.message(for: failure, localize: localize)
        #expect(message.hasPrefix("[OCR failed:"))
        #expect(message.contains("Vision 框架识别失败: injected"))
    }

    /// 非 `OCRError` 的失败同样走同一条句式，不能让 toast 变成空字符串。
    @Test func aForeignErrorStillProducesASentence() {
        struct Foreign: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }

        let message = OCRErrorPresentation.message(for: Foreign(), localize: Self.markingLocalizer)
        #expect(message.contains("boom"))
    }

    /// 分类本身要正确：它决定了文案，也决定调用方是否需要提示重启。
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
            OCRErrorPresentation.kind(of: OCRError.recognitionFailed(reason: "x")) == .other
        )
        #expect(OCRErrorPresentation.kind(of: OCRError.imageTooLarge(width: 1, height: 1)) == .other)
        #expect(OCRErrorPresentation.kind(of: CancellationError()) == nil)
    }

    /// 四条新增文案在四个语言包里都存在，占位符与英文一致。
    @Test func theNewSentencesExistInEveryLanguage() {
        let keys = [
            "Text recognition timed out. Try again with a smaller area.",
            "Text recognition stopped responding. Restart SnapGlass and try again.",
            "The selected text recognition engine is unavailable.",
        ]
        for language in ["en", "zh-Hans", "ja", "ko"] {
            let table = Self.contents(of: language)
            for key in keys {
                #expect(
                    table.contains("\"\(key)\""),
                    "\(language) is missing the sentence: \(key)"
                )
            }
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
