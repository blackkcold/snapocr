import Foundation

// MARK: - TesseractLibrary 诊断扩展

extension TesseractLibrary {
    /// 返回 Tesseract 库加载状态的诊断信息。
    ///
    /// 用于开发者模式和调试日志，输出 Tesseract 版本和安装路径。
    ///
    /// - Returns: 诊断描述字符串。
    var diagnosticsDescription: String {
        guard isAvailable else {
            return """
            Tesseract: 未安装
            请通过 Homebrew 安装: brew install tesseract
            或从 https://github.com/tesseract-ocr/tesseract 下载
            """
        }
        return """
        Tesseract: 已加载 (v\(version))
        语言数据路径: \(TesseractOCREngine.tessdataDirectory().path)
        语言包: \(availableLanguagePacks().joined(separator: ", "))
        """
    }

    /// 列出 tessdata 目录中已安装的语言包。
    ///
    /// - Returns: Tesseract 语言代码数组。
    private func availableLanguagePacks() -> [String] {
        let tessdataDir = TesseractOCREngine.tessdataDirectory()
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: tessdataDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        do {
            let files = try fileManager.contentsOfDirectory(atPath: tessdataDir.path)
            return files.compactMap { filename in
                guard filename.hasSuffix(".traineddata") else { return nil }
                return String(filename.dropLast(".traineddata".count))
            }.sorted()
        } catch {
            return []
        }
    }
}
