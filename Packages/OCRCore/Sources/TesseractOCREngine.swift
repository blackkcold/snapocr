import CoreGraphics
import Foundation

// MARK: - Tesseract Language Support

/// Tesseract 引擎语言代码工具。
///
/// 提供 Vision 框架语言代码与 Tesseract 语言代码之间的双向映射，
/// 以及语言包可用性检查。
///
/// 语言映射关系（Vision → Tesseract）:
/// - `en` / `en-US` / `en-GB` → `eng`
/// - `zh-Hans` → `chi_sim`
/// - `zh-Hant` → `chi_tra`
/// - `ja` / `ja-JP` → `jpn`
/// - `ko` / `ko-KR` → `kor`
/// - `fr` / `fr-FR` → `fra`
/// - `de` / `de-DE` → `deu`
/// - `es` / `es-ES` → `spa`
/// - `pt` / `pt-PT` → `por`
/// - `it` / `it-IT` → `ita`
enum TesseractLanguageSupport: Sendable {
    /// Vision 框架语言代码到 Tesseract 语言代码的映射表。
    static let visionToTesseract: [String: String] = [
        "en": "eng",
        "en-US": "eng",
        "en-GB": "eng",
        "zh-Hans": "chi_sim",
        "zh-Hant": "chi_tra",
        "ja": "jpn",
        "ja-JP": "jpn",
        "ko": "kor",
        "ko-KR": "kor",
        "fr": "fra",
        "fr-FR": "fra",
        "de": "deu",
        "de-DE": "deu",
        "es": "spa",
        "es-ES": "spa",
        "pt": "por",
        "pt-PT": "por",
        "it": "ita",
        "it-IT": "ita",
    ]

    /// Tesseract 语言代码到本地化展示名称的映射。
    static let displayNames: [String: String] = [
        "eng": "English",
        "chi_sim": "简体中文",
        "chi_tra": "繁體中文",
        "jpn": "日本語",
        "kor": "한국어",
        "fra": "Français",
        "deu": "Deutsch",
        "spa": "Español",
        "por": "Português",
        "ita": "Italiano",
    ]

    /// 所有支持的 Tesseract 语言代码集合。
    ///
    /// 包含设计文档中列出的 10 种语言:
    /// eng, chi_sim, chi_tra, jpn, kor, fra, deu, spa, por, ita。
    static let supportedTesseractLanguages: Set<String> = [
        "eng", "chi_sim", "chi_tra", "jpn", "kor",
        "fra", "deu", "spa", "por", "ita",
    ]

    /// 将 Vision 框架语言代码转换为 Tesseract 语言代码。
    ///
    /// - Parameter visionCode: Vision 框架语言代码（如 `"zh-Hans"`, `"en-US"`）。
    /// - Returns: 对应的 Tesseract 语言代码（如 `"chi_sim"`, `"eng"`）。
    ///   如果未找到映射，返回原代码。
    static func tesseractCode(for visionCode: String) -> String {
        // 尝试精确匹配
        if let code = visionToTesseract[visionCode] {
            return code
        }
        // 尝试短代码前缀匹配（如 "zh" → 取第一个匹配 "zh-Hans" 对应 "chi_sim"）
        let shortCode = String(visionCode.prefix(2))
        for (key, value) in visionToTesseract where key.hasPrefix(shortCode) {
            return value
        }
        return visionCode
    }

    /// 将多个 Vision 语言代码批量转换为 Tesseract 语言代码。
    ///
    /// - Parameter visionCodes: Vision 语言代码数组。
    /// - Returns: 去重后的 Tesseract 语言代码数组。
    static func tesseractCodes(for visionCodes: [String]) -> [String] {
        let codes = visionCodes.map { tesseractCode(for: $0) }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    /// 获取 Tesseract 语言代码的展示名称。
    ///
    /// - Parameter tesseractCode: Tesseract 语言代码（如 `"chi_sim"`）。
    /// - Returns: 本地化展示名称（如 `"简体中文"`）。
    static func displayName(for tesseractCode: String) -> String {
        displayNames[tesseractCode] ?? tesseractCode
    }
}

// MARK: - Tesseract Dynamic Library Bridge

/// Tesseract C API 的动态库桥接。
///
/// 使用 `dlopen`/`dlsym` 在运行时动态加载 `libtesseract`，
/// 避免编译时链接依赖。这样即使用户未安装 Tesseract，
/// 应用也能正常启动，仅在尝试使用 Tesseract 引擎时提示错误。
///
/// 库搜索路径:
/// 1. `libtesseract.dylib`（标准动态库搜索路径）
/// 2. `libtesseract.5.dylib`（Tesseract 5）
/// 3. `libtesseract.4.dylib`（Tesseract 4）
/// 4. `/usr/local/lib/libtesseract.dylib`（Intel Homebrew）
/// 5. `/opt/homebrew/lib/libtesseract.dylib`（Apple Silicon Homebrew）
final class TesseractLibrary: @unchecked Sendable {
    // MARK: - 单例

    /// 共享实例。
    static let shared = TesseractLibrary()

    // MARK: - 公开属性

    /// libtesseract 是否已成功加载。
    let isAvailable: Bool

    /// Tesseract 版本号（如 `"5.3.3"`）。
    let version: String

    // MARK: - C 函数指针类型

    private typealias TessBaseAPICreateFunc = @convention(c) () -> OpaquePointer?
    private typealias TessBaseAPIInit3Func = @convention(c) (
        OpaquePointer?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Int32
    private typealias TessBaseAPISetImageFunc = @convention(c) (
        OpaquePointer?,
        UnsafePointer<UInt8>?,
        Int32,
        Int32,
        Int32,
        Int32
    ) -> Void
    private typealias TessBaseAPIGetUTF8TextFunc = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias TessBaseAPIMeanTextConfFunc = @convention(c) (OpaquePointer?) -> Int32
    private typealias TessBaseAPIDeleteFunc = @convention(c) (OpaquePointer?) -> Void
    private typealias TessDeleteTextFunc = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias TessVersionFunc = @convention(c) () -> UnsafePointer<CChar>?
    private typealias TessBaseAPIRecognizeFunc = @convention(c) (OpaquePointer?) -> Int32

    // MARK: - 函数指针

    private let tessBaseAPICreate: TessBaseAPICreateFunc?
    private let tessBaseAPIInit3: TessBaseAPIInit3Func?
    private let tessBaseAPISetImage: TessBaseAPISetImageFunc?
    private let tessBaseAPIGetUTF8Text: TessBaseAPIGetUTF8TextFunc?
    private let tessBaseAPIMeanTextConf: TessBaseAPIMeanTextConfFunc?
    private let tessBaseAPIDelete: TessBaseAPIDeleteFunc?
    private let tessDeleteText: TessDeleteTextFunc?
    private let tessBaseAPIRecognize: TessBaseAPIRecognizeFunc?

    // MARK: - 初始化

    private init() {
        // 尝试按优先级顺序加载 libtesseract
        let libraryPaths = [
            "libtesseract.dylib",
            "libtesseract.5.dylib",
            "libtesseract.4.dylib",
            "/usr/local/lib/libtesseract.dylib",
            "/opt/homebrew/lib/libtesseract.dylib",
            "/opt/homebrew/lib/libtesseract.5.dylib",
            "/opt/homebrew/lib/libtesseract.4.dylib",
        ]

        var loadedHandle: UnsafeMutableRawPointer?
        for path in libraryPaths {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
                loadedHandle = handle
                break
            }
        }

        guard let handle = loadedHandle else {
            self.isAvailable = false
            self.version = ""
            self.tessBaseAPICreate = nil
            self.tessBaseAPIInit3 = nil
            self.tessBaseAPISetImage = nil
            self.tessBaseAPIGetUTF8Text = nil
            self.tessBaseAPIMeanTextConf = nil
            self.tessBaseAPIDelete = nil
            self.tessDeleteText = nil
            self.tessBaseAPIRecognize = nil
            return
        }

        // 加载所有函数符号
        func loadSymbol<T>(_ name: String) -> T? {
            guard let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        self.tessBaseAPICreate = loadSymbol("TessBaseAPICreate")
        self.tessBaseAPIInit3 = loadSymbol("TessBaseAPIInit3")
        self.tessBaseAPISetImage = loadSymbol("TessBaseAPISetImage")
        self.tessBaseAPIGetUTF8Text = loadSymbol("TessBaseAPIGetUTF8Text")
        self.tessBaseAPIMeanTextConf = loadSymbol("TessBaseAPIMeanTextConf")
        self.tessBaseAPIDelete = loadSymbol("TessBaseAPIDelete")
        self.tessDeleteText = loadSymbol("TessDeleteText")
        self.tessBaseAPIRecognize = loadSymbol("TessBaseAPIRecognize")

        // 获取版本号
        let versionFunc: TessVersionFunc? = loadSymbol("TessVersion")
        if let versionFunc, let verStr = versionFunc() {
            self.version = String(cString: verStr)
        } else {
            self.version = "unknown"
        }

        self.isAvailable = true
    }

    // MARK: - OCR 执行

    /// 使用 Tesseract 引擎对图像数据执行 OCR 识别。
    ///
    /// - Parameters:
    ///   - imageData: 图像的 RGBA 像素数据。
    ///   - width: 图像宽度（像素）。
    ///   - height: 图像高度（像素）。
    ///   - bytesPerRow: 每行字节数。
    ///   - languages: Tesseract 语言代码数组，用 `+` 连接后传入引擎。
    ///   - tessdataPath: tessdata 目录的路径。
    /// - Returns: 包含识别文本和平均置信度的元组。
    /// - Throws: `OCRError` 当初始化失败或识别过程出错时。
    func performOCR(
        imageData: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        languages: [String],
        tessdataPath: String
    ) throws -> (text: String, confidence: Float) {
        guard isAvailable,
              let create = tessBaseAPICreate,
              let init3 = tessBaseAPIInit3,
              let setImage = tessBaseAPISetImage,
              let getText = tessBaseAPIGetUTF8Text,
              let getConf = tessBaseAPIMeanTextConf,
              let delete = tessBaseAPIDelete,
              let deleteText = tessDeleteText,
              let recognize = tessBaseAPIRecognize
        else {
            throw OCRError.engineUnavailable(.tesseract(languageDataPath: URL(fileURLWithPath: tessdataPath)))
        }

        // 1. 创建 Tesseract API 实例
        guard let api = create() else {
            throw OCRError.recognitionFailed(reason: "Tesseract BaseAPI 创建失败")
        }

        // 使用 defer 确保释放
        defer { delete(api) }

        // 2. 初始化 Tesseract
        let langStr = languages.joined(separator: "+")
        let resultCode = init3(api, tessdataPath, langStr)

        guard resultCode == 0 else {
            throw OCRError.recognitionFailed(
                reason: "Tesseract 初始化失败 (code: \(resultCode))，请检查语言包 '\(langStr)' 是否已安装"
            )
        }

        // 3. 设置图像
        let bytesPerPixel = bytesPerRow / width
        imageData.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            setImage(api, ptr, Int32(width), Int32(height), Int32(bytesPerPixel), Int32(bytesPerRow))
        }

        // 4. 执行识别
        let recognizeResult = recognize(api)
        guard recognizeResult == 0 else {
            throw OCRError.recognitionFailed(
                reason: "Tesseract 识别失败 (code: \(recognizeResult))"
            )
        }

        // 5. 获取识别文本
        guard let textPtr = getText(api) else {
            throw OCRError.recognitionFailed(reason: "Tesseract 未返回识别结果")
        }
        let recognizedText = String(cString: textPtr)
        deleteText(textPtr)

        // 6. 获取平均置信度（Tesseract 返回 0-100 的整数，转换为 0.0-1.0 的浮点数）
        let meanConfidence = getConf(api)
        let confidence = Float(meanConfidence) / 100.0

        return (recognizedText, confidence)
    }
}

// MARK: - Tesseract OCR Engine

/// Tesseract OCR 降级引擎。
///
/// 使用 Tesseract OCR 引擎（通过动态库加载）进行文本识别，
/// 作为 Apple Vision 框架的补充/降级选项。
///
/// 特性:
/// - 通过 `dlopen` 动态加载 libtesseract，无需编译时链接
/// - 支持多语言识别（英文、中文简繁体、日文、韩文等）
/// - 语言包动态检测（从 tessdata 目录读取）
/// - 置信度评分（Tesseract 内部置信度）
/// - 处理耗时统计
/// - 日志回调支持
///
/// ## 使用条件
/// 1. 系统需安装 Tesseract（可通过 Homebrew 安装: `brew install tesseract`）
/// 2. 语言包需下载到 `~/Library/Application Support/SnapGlass/tessdata/` 目录
/// 3. 可通过 `LanguagePackDownloader` 下载语言包
///
/// ## 使用示例
/// ```swift
/// let engine = TesseractOCREngine()
/// let result = try await engine.recognize(
///     image: cgImage,
///     languages: ["zh-Hans", "en"],
///     options: OCROptions()
/// )
/// print("识别文本: \(result.text), 置信度: \(result.confidence)")
/// ```
final class TesseractOCREngine: OCRProtocol, @unchecked Sendable {
    typealias PlatformImageType = CGImage

    // MARK: - 协议属性

    let engineType: OCREngineType
    var logHandler: ((OCRLogEntry) -> Void)?
    private let languageDataPath: URL

    // MARK: - 常量

    /// Tesseract 语言数据目录的子路径（相对于 Application Support 目录）。
    private static let tessdataSubpath = "SnapGlass/tessdata"

    // MARK: - 初始化

    init(languageDataPath: URL? = nil) {
        let path = languageDataPath ?? Self.tessdataDirectory()
        self.languageDataPath = path
        self.engineType = .tesseract(languageDataPath: path)
    }

    // MARK: - OCRProtocol

    /// 对图像执行 Tesseract OCR 识别。
    ///
    /// 处理流程:
    /// 1. 检查 tessdata 目录是否存在
    /// 2. 将 Vision 语言代码转换为 Tesseract 语言代码
    /// 3. 检查所需的语言包是否可用
    /// 4. 检查 libtesseract 是否已加载
    /// 5. 将 CGImage 转换为 RGBA 像素数据
    /// 6. 初始化 Tesseract 引擎并执行识别
    /// 7. 提取文本和置信度
    /// 8. 构建 OCRResult 并回调日志
    ///
    /// - Parameters:
    ///   - image: 要识别的 CGImage。
    ///   - languages: 语言列表，按优先级排序（Vision 框架语言代码）。
    ///   - options: 识别选项。
    /// - Returns: 包含文本、置信度、引擎信息的 `OCRResult`。
    /// - Throws:
    ///   - `OCRError.engineUnavailable` 当 Tesseract 未安装或语言数据不可用时。
    ///   - `OCRError.languageNotSupported` 当语言包未下载时。
    ///   - `OCRError.recognitionFailed` 当识别过程出错时。
    func recognize(
        image: CGImage,
        languages: [String],
        options: OCROptions
    ) async throws -> OCRResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. 检查 tessdata 目录是否存在
        let tessdataDir = languageDataPath
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let tessdataExists = fileManager.fileExists(atPath: tessdataDir.path, isDirectory: &isDirectory)

        guard tessdataExists, isDirectory.boolValue else {
            throw OCRError.engineUnavailable(.tesseract(languageDataPath: tessdataDir))
        }

        // 2. 将 Vision 语言代码转换为 Tesseract 语言代码并去重
        let tesseractLangs = TesseractLanguageSupport.tesseractCodes(for: languages)

        guard !tesseractLangs.isEmpty else {
            throw OCRError.recognitionFailed(reason: "未找到有效的 Tesseract 语言代码，输入语言: \(languages)")
        }

        // 3. 检查所需的语言包是否存在
        for lang in tesseractLangs {
            let packPath = tessdataDir.appendingPathComponent("\(lang).traineddata")
            guard fileManager.fileExists(atPath: packPath.path) else {
                throw OCRError.languageNotSupported(
                    "Tesseract 语言包 '\(lang)' (\(TesseractLanguageSupport.displayName(for: lang))) 未安装。请使用 LanguagePackDownloader 下载，或手动放置于 \(packPath.path)"
                )
            }
        }

        // 4. 检查 libtesseract 是否已加载
        guard TesseractLibrary.shared.isAvailable else {
            throw OCRError.engineUnavailable(.tesseract(languageDataPath: tessdataDir))
        }

        // 5. 将 CGImage 转换为 RGBA 像素数据
        let (pixelData, width, height, bytesPerRow) = try Self.convertToRGBAData(image: image)

        // 6. 执行 Tesseract OCR
        let (recognizedText, rawConfidence) = try TesseractLibrary.shared.performOCR(
            imageData: pixelData,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            languages: tesseractLangs,
            tessdataPath: tessdataDir.path
        )

        // 7. 构建 OCRResult
        let processingTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // Tesseract 不提供逐行 bounding box，需通过后处理拆分
        let lines = Self.splitTextIntoLines(recognizedText, confidence: rawConfidence)

        let result = OCRResult(
            text: recognizedText,
            confidence: rawConfidence,
            engineType: .tesseract(languageDataPath: tessdataDir),
            layoutPreserved: false,
            observations: lines,
            processingTimeMs: processingTime
        )

        // 8. 日志回调
        logHandler?(OCRLogEntry(
            timestamp: Date(),
            visionConfidence: 0,
            tesseractConfidence: rawConfidence,
            visionText: "",
            tesseractText: recognizedText,
            visionTimeMs: 0,
            tesseractTimeMs: processingTime
        ))

        return result
    }

    /// 返回当前可用的 Tesseract 语言列表。
    ///
    /// 通过扫描 tessdata 目录中的 `.traineddata` 文件，检测已安装的语言包。
    /// 即使 Tesseract 库未安装，此方法也能返回已下载的语言包列表。
    ///
    /// - Returns: Vision 框架语言代码数组（如 `["en", "zh-Hans", "ja"]`）。
    func supportedLanguages() -> [String] {
        let tessdataDir = languageDataPath
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: tessdataDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        do {
            let files = try fileManager.contentsOfDirectory(atPath: tessdataDir.path)
            let detected: [String] = files.compactMap { filename in
                guard filename.hasSuffix(".traineddata") else { return nil }
                let code = String(filename.dropLast(".traineddata".count))
                guard TesseractLanguageSupport.supportedTesseractLanguages.contains(code) else { return nil }
                return code
            }

            if detected.isEmpty {
                return []
            }

            // 将 Tesseract 代码映射回 Vision 代码
            return detected.map { code in
                TesseractLanguageSupport.visionToTesseract.first { $0.value == code }?.key ?? code
            }.sorted()
        } catch {
            return []
        }
    }

    // MARK: - 私有方法

    /// 获取 tessdata 目录路径。
    ///
    /// 目录位置: `~/Library/Application Support/SnapGlass/tessdata/`
    ///
    /// - Returns: tessdata 目录的 URL。
    fileprivate static func tessdataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(tessdataSubpath)
    }

    /// 将 CGImage 转换为 RGBA 像素数据。
    ///
    /// 创建一个 32-bit RGBA 位图上下文，将 CGImage 绘制到其中，
    /// 确保像素数据格式与 Tesseract 兼容。
    ///
    /// - Parameter image: 要转换的 CGImage。
    /// - Returns: 包含像素数据、宽度、高度和每行字节数的元组。
    /// - Throws: `OCRError.recognitionFailed` 当转换失败时。
    private static func convertToRGBAData(image: CGImage) throws -> (data: Data, width: Int, height: Int, bytesPerRow: Int) {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width

        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw OCRError.recognitionFailed(reason: "无法创建位图上下文以转换图像数据")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return (Data(rawData), width, height, bytesPerRow)
    }

    /// 将 Tesseract 识别的文本按行拆分。
    ///
    /// Tesseract 的 `GetUTF8Text` 返回完整文本（用 `\n` 分隔行），
    /// 但不提供逐行的置信度和位置信息。此方法按换行符拆分文本，
    /// 并为每一行使用整体置信度。
    ///
    /// - Parameters:
    ///   - text: Tesseract 返回的完整识别文本。
    ///   - confidence: 整体平均置信度。
    /// - Returns: OCRLine 数组（不含位置信息）。
    private static func splitTextIntoLines(_ text: String, confidence: Float) -> [OCRLine] {
        let lines = text.components(separatedBy: "\n")
        return lines.filter { !$0.isEmpty }.map { line in
            OCRLine(
                text: line,
                confidence: confidence,
                boundingBox: .zero // Tesseract 逐行 API 不提供 bounding box
            )
        }
    }
}

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
