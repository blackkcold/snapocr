import CoreGraphics
import Foundation

// MARK: - Vision 识别回退策略

/// 判断 `.accurate` 结果是否为空，以及是否应采用 `.fast` 的结果。
///
/// Vision 的 `.accurate` 级别在「特定内容 × 大画布」组合下会静默返回 0 条
/// （本机 3840×2160、5120×2880 可稳定复现）。空结果不能直接当作最终答案，
/// 需要用 `.fast` 作为安全网再确认一次。
///
/// 兜底只在 `.accurate` 完全为空时触发：实测 `.fast` 对中文截图会返回字符数
/// 更多的乱码，用「文字量更多」去替换 `.accurate` 的少量正确结果会把中文换成
/// 乱码。这里也绝不使用置信度阈值过滤文字。
enum VisionRecognitionPolicy {
    /// 小于该像素数的图片是小裁切，第二次识别很少能带来收益。
    static let minimumRetryPixelCount = 200_000

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
