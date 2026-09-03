import Foundation

// MARK: - HistoryActor CSV Export

extension HistoryActor {
    /// 日期格式化器 (CSV/纯文本导出用)
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 从条目数组构建 CSV 数据
    static func buildCSV(from entries: [HistoryEntry]) -> Data {
        let header = "ID,Timestamp,Text,Confidence,CaptureMode,SourceType,SourceApp,WindowTitle,Favourite,Tags\n"
        let rows = entries.map { entry -> String in
            let id = entry.id.uuidString
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let text = csvEscape(entry.textContent)
            let confidence = String(format: "%.4f", entry.ocrConfidence)
            let mode = csvEscape(entry.captureMode)
            let sourceType = entry.sourceType.rawValue
            let app = csvEscape(entry.sourceAppName ?? "")
            let window = csvEscape(entry.sourceWindowTitle ?? "")
            let fav = entry.isFavourite ? "Yes" : "No"
            let tags = csvEscape(entry.tags.joined(separator: ";"))
            return "\(id),\(timestamp),\(text),\(confidence),\(mode),\(sourceType),\(app),\(window),\(fav),\(tags)"
        }

        let csv = header + rows.joined(separator: "\n")
        return csv.data(using: .utf8) ?? Data()
    }

    /// CSV 字段转义
    static func csvEscape(_ text: String) -> String {
        if text.contains(",") || text.contains("\"") || text.contains("\n") {
            let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return text
    }
}
