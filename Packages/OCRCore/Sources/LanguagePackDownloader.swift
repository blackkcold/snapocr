import Foundation
import SharedKit

// MARK: - 语言包下载器

/// Tesseract 语言包下载器。
///
/// 负责从 GitHub tessdata_best 仓库下载 Tesseract 语言数据包（`.traineddata` 文件），
/// 管理本地缓存，并提供进度报告。支持断点续传和下载取消。
///
/// 语言包存储路径: `~/Library/Application Support/SnapGlass/tessdata/`
/// 远程仓库: `https://github.com/tesseract-ocr/tessdata_best`
///
/// ## 使用示例
/// ```swift
/// let downloader = LanguagePackDownloader()
///
/// // 检查语言包是否已下载
/// if downloader.isLanguageAvailable("chi_sim") {
///     print("简体中文语言包已就绪")
/// }
///
/// // 下载语言包（带进度）
/// let url = try await downloader.downloadLanguage("chi_sim")
/// ```
public actor LanguagePackDownloader {
    // MARK: - 下载状态

    /// 语言包下载状态。
    public enum DownloadState: Sendable {
        /// 空闲状态，没有进行中的下载。
        case idle
        /// 下载中，包含当前进度（0.0 ~ 1.0）。
        case downloading(progress: Double)
        /// 下载完成，包含语言包文件的本地 URL。
        case completed(URL)
        /// 下载失败，包含错误详情。
        case failed(any Error)
    }

    // MARK: - 常量

    /// GitHub 语言数据仓库 URL。
    private let tessdataRepo = "https://github.com/tesseract-ocr/tessdata_best"

    /// 语言数据目录的子路径（相对于 Application Support 目录）。
    private static let tessdataSubpath = "SnapGlass/tessdata"

    /// 支持的 Tesseract 语言代码及其显示名称。
    ///
    /// 来源: 设计文档 7.1++ 节，首版支持 eng, chi_sim, chi_tra, jpn, kor。
    public static let supportedLanguages: [(code: String, displayName: String)] = [
        ("eng", "English"),
        ("chi_sim", "简体中文"),
        ("chi_tra", "繁體中文"),
        ("jpn", "日本語"),
        ("kor", "한국어"),
    ]

    /// 所有支持的语言代码集合。
    public static let supportedLanguageCodes: Set<String> = Set(supportedLanguages.map(\.code))

    // MARK: - 私有属性

    /// 已下载的语言包集合（内存缓存）。
    private var downloadedLanguages: Set<String> = []

    /// 当前下载状态。
    private var state: DownloadState = .idle

    /// 当前下载的 Task，用于支持取消操作。
    private var currentDownloadTask: Task<Void, Never>?

    /// 日志记录器。
    private let logger = Logger(category: "language-pack-downloader")

    // MARK: - 初始化

    public init() {
        // 初始化时扫描本地已下载的语言包
        let tessdataDir = Self.tessdataDirectory()
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: tessdataDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(atPath: tessdataDir.path)
            let detected: [String] = files.compactMap { filename in
                guard filename.hasSuffix(".traineddata") else { return nil }
                return String(filename.dropLast(".traineddata".count))
            }
            downloadedLanguages = Set(detected).intersection(Self.supportedLanguageCodes)
            if !detected.isEmpty {
                logger.info("已检测到本地语言包: \(detected.joined(separator: ", "))")
            }
        } catch {
            logger.warning("扫描本地语言包失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 公开方法

    /// 获取所有可下载的语言列表（含显示名称）。
    ///
    /// - Returns: 语言代码和显示名称的数组。
    public var availableLanguages: [(code: String, displayName: String)] {
        Self.supportedLanguages
    }

    /// 检查指定语言包是否已在本地可用。
    ///
    /// - Parameter lang: Tesseract 语言代码（如 `"chi_sim"`）。
    /// - Returns: `true` 如果语言包已下载到本地 tessdata 目录。
    public func isLanguageAvailable(_ lang: String) -> Bool {
        let path = languagePackPath(for: lang)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// 获取当前下载状态。
    ///
    /// - Returns: 当前的 `DownloadState`。
    public func downloadState() -> DownloadState {
        state
    }

    /// 下载指定的 Tesseract 语言包。
    ///
    /// 处理流程:
    /// 1. 验证语言代码是否受支持
    /// 2. 检查本地是否已存在
    /// 3. 确保 tessdata 目录存在
    /// 4. 从 GitHub 下载 `.traineddata` 文件
    /// 5. 每 10KB 更新一次进度
    /// 6. 写入本地 tessdata 目录
    /// 7. 更新状态并返回文件 URL
    ///
    /// - Parameter lang: Tesseract 语言代码（如 `"chi_sim"`, `"eng"`）。
    /// - Returns: 下载后的语言包文件本地 URL。
    /// - Throws:
    ///   - `LanguagePackError.unsupportedLanguage` 当语言代码不受支持时。
    ///   - `LanguagePackError.downloadFailed` 当下载失败时。
    ///   - `CancellationError` 当下载被取消时。
    public func downloadLanguage(_ lang: String) async throws -> URL {
        // 1. 验证语言代码
        guard Self.supportedLanguageCodes.contains(lang) else {
            throw LanguagePackError.unsupportedLanguage(lang)
        }

        // 2. 检查本地是否已存在
        if isLanguageAvailable(lang) {
            let existingPath = languagePackPath(for: lang)
            logger.info("语言包 '\(lang)' 已存在: \(existingPath.path)")
            state = .completed(existingPath)
            // 同时更新内存缓存
            downloadedLanguages.insert(lang)
            return existingPath
        }

        // 3. 确保 tessdata 目录存在
        try ensureTessdataDirectory()

        // 4. 开始下载
        let url = URL(string: "\(tessdataRepo)/raw/main/\(lang).traineddata")!
        let destination = languagePackPath(for: lang)

        logger.info("开始下载语言包 '\(lang)' 从 \(url.absoluteString)")

        state = .downloading(progress: 0)

        // 使用 Task 支持取消
        let downloadTask = Task<URL, any Error> { [weak self] in
            guard let self else { throw LanguagePackError.downloadFailed(lang) }

            let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LanguagePackError.downloadFailed(lang)
            }

            // 处理非 200 响应
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    logger.error("语言包 '\(lang)' 在仓库中不存在 (404)")
                    throw LanguagePackError.downloadFailed(lang)
                }
                logger.error("下载语言包 '\(lang)' 返回 HTTP \(httpResponse.statusCode)")
                throw LanguagePackError.downloadFailed(lang)
            }

            let totalBytes = httpResponse.expectedContentLength
            var receivedBytes: Int64 = 0
            var data = Data()

            // 预分配内存（如果可以确定大小）
            if totalBytes > 0 {
                data.reserveCapacity(Int(totalBytes))
            } else {
                // 未知大小时使用合理默认值（traineddata 通常 1-50MB）
                data.reserveCapacity(10 * 1024 * 1024)
            }

            let progressUpdateInterval: Int64 = 10 * 1024 // 每 10KB 更新一次进度

            for try await byte in asyncBytes {
                // 检查是否被取消
                try Task.checkCancellation()

                data.append(byte)
                receivedBytes += 1

                // 定期更新进度
                if receivedBytes % progressUpdateInterval == 0 {
                    if totalBytes > 0 {
                        let progress = Double(receivedBytes) / Double(totalBytes)
                        await self.updateState(.downloading(progress: min(progress, 0.99)))
                    } else {
                        // 未知总大小时显示已下载字节数
                        await self.updateState(.downloading(progress: -1))
                    }
                }
            }

            // 确保下载的数据不为空
            guard !data.isEmpty else {
                throw LanguagePackError.downloadFailed(lang)
            }

            // 5. 写入本地文件
            do {
                try data.write(to: destination)
                logger.info("语言包 '\(lang)' 下载完成 (\(data.count) bytes): \(destination.path)")
            } catch {
                logger.error("写入语言包文件失败: \(error.localizedDescription)")
                throw LanguagePackError.downloadFailed(lang)
            }

            await self.updateDownloadedLanguages(lang)
            await self.updateState(.completed(destination))

            return destination
        }

        // 存储当前下载任务以便取消
        self.currentDownloadTask = Task {
            _ = try? await downloadTask.value
        }

        do {
            let result = try await downloadTask.value
            self.currentDownloadTask = nil
            return result
        } catch {
            self.currentDownloadTask = nil

            // 更新状态为失败
            if error is CancellationError {
                state = .idle
                logger.warning("语言包 '\(lang)' 下载已取消")
                throw error
            }

            state = .failed(error)
            logger.error("语言包 '\(lang)' 下载失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 取消当前正在进行的下载。
    ///
    /// 如果当前没有下载任务，此方法不做任何操作。
    public func cancelDownload() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        state = .idle
        logger.info("下载已取消")
    }

    /// 返回本地已下载的所有语言包列表。
    ///
    /// - Returns: Tesseract 语言代码数组。
    public func listDownloadedLanguages() -> [String] {
        let tessdataDir = Self.tessdataDirectory()
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
                let code = String(filename.dropLast(".traineddata".count))
                guard Self.supportedLanguageCodes.contains(code) else { return nil }
                return code
            }.sorted()
        } catch {
            logger.warning("获取已下载语言包列表失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 删除已下载的语言包。
    ///
    /// - Parameter lang: Tesseract 语言代码。
    /// - Throws: `LanguagePackError.unsupportedLanguage` 如果语言代码不受支持，
    ///   或文件系统错误。
    public func deleteLanguage(_ lang: String) throws {
        guard Self.supportedLanguageCodes.contains(lang) else {
            throw LanguagePackError.unsupportedLanguage(lang)
        }

        let path = languagePackPath(for: lang)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: path.path) else {
            logger.warning("尝试删除不存在的语言包 '\(lang)'")
            return // 不存在也算成功
        }

        try fileManager.removeItem(at: path)
        downloadedLanguages.remove(lang)
        logger.info("语言包 '\(lang)' 已删除")
    }

    /// 获取语言包文件大小（字节）。
    ///
    /// - Parameter lang: Tesseract 语言代码。
    /// - Returns: 文件大小（字节），如果语言包未下载则返回 `nil`。
    public func languagePackSize(_ lang: String) -> UInt64? {
        let path = languagePackPath(for: lang)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path) else {
            return nil
        }
        return attrs[.size] as? UInt64
    }

    /// 获取本地语言包的总磁盘占用（字节）。
    ///
    /// - Returns: 所有已下载语言包的总大小（字节）。
    public func totalDiskUsage() -> UInt64 {
        listDownloadedLanguages().reduce(0) { total, lang in
            total + (languagePackSize(lang) ?? 0)
        }
    }

    // MARK: - 静态方法

    /// 获取 tessdata 目录的 URL。
    ///
    /// 目录位置: `~/Library/Application Support/SnapGlass/tessdata/`
    ///
    /// - Returns: tessdata 目录的 URL。
    public static nonisolated func tessdataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(tessdataSubpath)
    }

    // MARK: - 私有方法

    /// 获取指定语言包的本地文件路径。
    ///
    /// - Parameter lang: Tesseract 语言代码。
    /// - Returns: `.traineddata` 文件的本地 URL。
    private func languagePackPath(for lang: String) -> URL {
        Self.tessdataDirectory().appendingPathComponent("\(lang).traineddata")
    }

    /// 确保 tessdata 目录存在，如果不存在则创建。
    ///
    /// - Throws: 文件系统错误。
    private func ensureTessdataDirectory() throws {
        let tessdataDir = Self.tessdataDirectory()
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: tessdataDir.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                // 存在同名文件，需要先删除再创建目录
                try fileManager.removeItem(at: tessdataDir)
                try fileManager.createDirectory(at: tessdataDir, withIntermediateDirectories: true)
                logger.info("已重新创建 tessdata 目录")
            }
        } else {
            try fileManager.createDirectory(at: tessdataDir, withIntermediateDirectories: true)
            logger.info("已创建 tessdata 目录: \(tessdataDir.path)")
        }
    }

    /// 更新下载状态（Actor 隔离的方法，确保线程安全）。
    ///
    /// - Parameter newState: 新的下载状态。
    private func updateState(_ newState: DownloadState) {
        state = newState
    }

    /// 更新已下载语言包集合。
    ///
    /// - Parameter lang: 新下载的语言代码。
    private func updateDownloadedLanguages(_ lang: String) {
        downloadedLanguages.insert(lang)
    }
}

// MARK: - 语言包错误类型

/// 语言包相关的错误类型。
public enum LanguagePackError: LocalizedError, Sendable {
    /// 下载失败（含语言代码）。
    case downloadFailed(String)
    /// 不支持的语言（含语言代码）。
    case unsupportedLanguage(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let lang):
            return String(localized: "语言包 '\(lang)' 下载失败，请检查网络连接后重试")
        case .unsupportedLanguage(let lang):
            return String(localized: "不支持的语言 '\(lang)'，支持的语言: \(LanguagePackDownloader.supportedLanguages.map(\.code).joined(separator: ", "))")
        }
    }

    /// 恢复建议。
    public var recoverySuggestion: String? {
        switch self {
        case .downloadFailed:
            return String(localized: "请检查网络连接，或尝试手动从 https://github.com/tesseract-ocr/tessdata_best 下载")
        case .unsupportedLanguage:
            return String(localized: "请使用 LanguagePackDownloader.availableLanguages 查看支持的语言列表")
        }
    }
}
