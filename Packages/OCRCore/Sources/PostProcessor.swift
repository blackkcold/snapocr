import Foundation

public struct PostProcessor: Sendable {

    public init() {}

    public func process(_ result: OCRResult) -> OCRResult {
        // TODO: 实现后处理逻辑
        // 1. 合并相邻行
        // 2. URL 检测与链接化
        // 3. 词典替换与纠错
        return result
    }

    public func detectURLs(in text: String) -> [URL] {
        // TODO: 使用 NSDataDetector 检测 URL
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
    }
}
