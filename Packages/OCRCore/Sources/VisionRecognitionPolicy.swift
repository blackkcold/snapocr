import CoreGraphics
import Foundation

// MARK: - Vision 识别回退策略

/// 判断 `.accurate` 的结果是否「明显偏少」，以及该如何补齐。
///
/// Vision 的 `.accurate` 在「特定内容 × 大画布」组合下会静默丢掉大部分文本行，
/// 既不是报错，也不一定是空结果：实测 3840×2160、13pt 中文 UI 文本只返回 24 个
/// 标签中的 3–5 个。同一张图缩到 3000 宽后重跑，同一引擎返回 24/24，说明丢行
/// 来自单次请求要覆盖的区域太大，而不是图上没有文字。
///
/// 这里有三条彼此独立的判定：
/// 1. 未分块的大画布 + 结果明显偏少 → 以 3000 宽重跑同一引擎（`shouldRetryAtSmallerScale`）。
/// 2. 缩小重跑的结果明显更完整 → 是否采用这次重跑的结果。
/// 3. `.accurate` 完全为空 → 再用 `.fast` 确认一次（`shouldRetryWithFast`）。
///
/// 第 2 条只在同一引擎、同一语言列表、同一识别级别之间比较文字量，比较的是
/// 「这次请求覆盖整幅图时丢了多少行」。跨引擎比较不成立：实测 `.fast` 对中文
/// 会返回字符数更多的乱码（`E]lAI'` / `£iJt+`），用「文字更多就替换」会把中文
/// 换成乱码。跨引擎场景只用「是否为空」判定（`prefersFastResult`）。这里也
/// 绝不使用置信度阈值过滤文字。
enum VisionRecognitionPolicy {
    /// 小于该像素数的图片是小裁切，第二次识别很少能带来收益。
    static let minimumRetryPixelCount = 200_000

    /// 缩小重跑时使用的长边像素数。
    ///
    /// 3000 是实测值：3840×2160 的 13pt 中文界面截图整幅识别只得到 3/24 个标签，
    /// 缩到 3000 宽后同一引擎得到 24/24。再往下缩会开始丢小字。
    static let retryLongestSide: CGFloat = 3000

    /// 「结果明显偏少」的非空白字符密度下限（每百万像素字符数）。
    ///
    /// 实测（本机，3840×2160，`zh-Hans` 优先）：
    /// - 丢行的 13pt 中文界面截图：0.7 字符/Mpx（24 个标签只读到 3 个）；
    /// - 正常的 4K 中文界面：7.0–8.1 字符/Mpx；
    /// - 正常的 4K 英文列表：7.0 字符/Mpx。
    ///
    /// 4.0 落在丢行与正常之间，两侧各留约 4 倍与 1.75 倍余量。
    ///
    /// 内容本来就稀疏的截图（例如 4K 上只有一个三按钮对话框）也会低于这条线：
    /// 代价是多一次请求（实测空白 5K 画布 +27ms，有文字 +110ms），而第 2 条判定
    /// 只在结果至少翻倍时才采用，所以误触发不会降低识别质量。
    static let minimumCharactersPerMegapixel = 4.0

    /// 统计结果中的非空白字符数。
    ///
    /// 用字符数而不是行数：同一行被拆成多段时行数会虚高，字符数才反映「读到了多少字」。
    static func nonWhitespaceCharacterCount(_ lines: [OCRLine]) -> Int {
        lines.reduce(0) { total, line in
            total + line.text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
        }
    }

    /// `.accurate` 在这个尺寸上是否该以更小的画布重跑一次。
    ///
    /// 只有当图片大到「单次请求要覆盖整幅画布」，同时结果密度明显低于正常界面时
    /// 才重跑。三种情况一律不重跑：
    /// - 长边不超过 `retryLongestSide`：已经是小图，没有可缩的余量；
    /// - 长边超过 `MemoryGuard.maxImageWidth`：这类图由 `OCRPipeline` 分块识别，
    ///   每块已压到 2048，再缩只会丢小字；
    /// - 结果密度正常：说明这一遍没有丢行，重跑没有意义。
    ///
    /// - Parameters:
    ///   - characterCount: `.accurate` 结果中的非空白字符数。
    ///   - imageWidth: 图片像素宽。
    ///   - imageHeight: 图片像素高。
    /// - Returns: 是否应以 `retryLongestSide` 重跑一次。
    static func shouldRetryAtSmallerScale(
        characterCount: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> Bool {
        let longestSide = CGFloat(max(imageWidth, imageHeight))
        guard longestSide > retryLongestSide, longestSide <= MemoryGuard.maxImageWidth else {
            return false
        }
        let megapixels = Double(imageWidth) * Double(imageHeight) / 1_000_000
        guard megapixels > 0 else { return false }
        return Double(characterCount) / megapixels < minimumCharactersPerMegapixel
    }

    /// 缩小重跑的结果是否明显比全幅结果更完整。
    ///
    /// 先要求严格更多，再要求至少翻倍：小幅波动（同一标签换个边界、多认出一个标点）
    /// 不该触发替换，只有「整幅图丢掉大半文本」被补回来才值得采用。
    /// 全幅结果为空时，只要重跑读到任何文字就采用。
    ///
    /// 实测：3840×2160 的 13pt 中文截图全幅 6 个字符、缩到 3000 宽后 55 个字符
    /// （9.2 倍）；同一内容读到 24 个标签时两边都是 55 个字符，不会替换。
    ///
    /// 采用方式是整体替换而不是叠加两次结果：同一段文字会被两次请求以不同边界
    /// 各读一遍，合并需要按内容去重，而这里没有可靠的对齐信息。替换的代价是
    /// 偶尔丢掉全幅结果已经读到的一两个标签。实测 225 个触发用例、122 次采用中，
    /// 锚点总数净增 953 个，最差的一次是持平，没有净减少——所以替换是划算的。
    ///
    /// - Parameters:
    ///   - primary: 全幅 `.accurate` 的结果。
    ///   - retry: 缩小后同一引擎的结果。
    /// - Returns: 是否应采用重跑的结果。
    static func prefersSmallerScaleResult(primary: [OCRLine], retry: [OCRLine]) -> Bool {
        let retryCharacters = nonWhitespaceCharacterCount(retry)
        guard retryCharacters > 0 else { return false }
        let primaryCharacters = nonWhitespaceCharacterCount(primary)
        guard primaryCharacters > 0 else { return true }
        return retryCharacters >= primaryCharacters * 2
    }

    /// `.accurate` 没有识别到任何文本时，是否还应跑一次 `.fast`。
    static func shouldRetryWithFast(lineCount: Int, imagePixelCount: Int) -> Bool {
        lineCount == 0 && imagePixelCount >= minimumRetryPixelCount
    }

    /// `.fast` 是否应替换 `.accurate` 的结果。
    ///
    /// 仅在 `.accurate` 什么都没识别出来、`.fast` 至少识别到内容时使用。
    /// 绝不按文字量或置信度替换已有结果。
    static func prefersFastResult(accurate: [OCRLine], fast: [OCRLine]) -> Bool {
        accurate.isEmpty && !fast.isEmpty
    }
}
