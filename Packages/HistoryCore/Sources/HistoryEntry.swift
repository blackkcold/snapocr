import Foundation

/// 历史记录条目
///
/// 表示一次截图/OCR操作的完整记录。包含文本内容、元数据和文件路径引用。
/// 在内存中使用明文表示，持久化时由 `HistoryActor` 使用 CryptoKit AES-GCM 加密存储。
///
/// - 截图原图: 加密存储在 `History/images/<uuid>.enc`
/// - OCR 文本: 作为条目 JSON 的一部分加密存储
/// - 缩略图: 不加密存储在 `History/thumbs/<uuid>.png`
///
/// 符合 `Sendable` 以支持跨 actor 传递，符合 `Codable` 用于序列化存储。
public struct HistoryEntry: Sendable, Identifiable, Codable {

    // MARK: - Properties

    /// 唯一标识符
    public let id: UUID

    /// 创建时间戳
    public let timestamp: Date

    /// 识别文本内容
    ///
    /// 当完整 OCR 文本保存偏好关闭时，此字段存储空字符串 `""`。
    /// 空字符串不一定表示 OCR 结果为空，也可能表示用户关闭了全文持久化。
    ///
    /// 内存中为明文，便于直接使用。持久化时整个条目以 AES-GCM 加密后写入磁盘。
    public var textContent: String

    /// OCR 置信度 (0.0–1.0)
    ///
    /// 低于 0.7 时引擎会展示降级提示。
    public var ocrConfidence: Float

    /// 截图模式
    ///
    /// 可选值: `"area"`, `"window"`, `"fullscreen"`, `"scroll"`
    public let captureMode: String

    /// 数据来源类型
    ///
    /// 标识此次捕获的触发方式。
    public let sourceType: HistorySourceType

    /// 截图来源应用名称
    ///
    /// 例如 `"Safari"`, `"Xcode"`, `"Terminal"`。如果无法确定则为 `nil`。
    public let sourceAppName: String?

    /// 截图来源窗口标题
    ///
    /// 例如 `"SnapGlass 设计文档.md — Obsidian"`。如果无法确定则为 `nil`。
    public let sourceWindowTitle: String?

    /// 加密截图文件的存储路径
    ///
    /// 指向 `History/images/` 目录下的 AES-GCM 加密图片文件。
    /// 需要通过 `HistoryActor` 解密后才能读取原始图片数据。
    public var imagePath: URL?

    /// 未加密缩略图的存储路径
    ///
    /// 指向 `History/thumbs/` 目录下的 PNG 缩略图文件，可直接读取。
    public var thumbnailPath: URL?

    /// 是否已收藏
    ///
    /// 收藏的条目在清理时享有更高保留优先级。
    public var isFavourite: Bool

    /// 是否为受保护条目
    ///
    /// 置顶（⌘P）产生的条目置为 `true`，自动清理不会淘汰或剥离其数据。
    /// 用户手动删除（`delete(id:)` / `clear()`）仍然生效。
    /// 该字段为后加字段，旧记录解码时缺失，默认回退为 `false`。
    public var isProtected: Bool

    /// 用户自定义标签
    ///
    /// 支持多标签分类，标签名不区分大小写。
    public var tags: [String]

    /// Optional so existing v2 records remain readable. The canonical image is
    /// never overwritten; this points to an immutable edited image/thumbnail pair.
    public var imageRevision: UUID?
    public var canRestoreOriginal: Bool { imageRevision != nil && imagePath != nil }

    // MARK: - Initialization

    /// 创建历史记录条目
    ///
    /// - Parameters:
    ///   - id: 唯一标识符，默认自动生成
    ///   - textContent: OCR 识别文本
    ///   - ocrConfidence: 识别置信度
    ///   - captureMode: 截图模式
    ///   - sourceType: 数据来源类型，默认 `.screenshot`
    ///   - sourceAppName: 来源应用名称，可选
    ///   - sourceWindowTitle: 来源窗口标题，可选
    ///   - imagePath: 加密截图路径，可选
    ///   - thumbnailPath: 缩略图路径，可选
    ///   - isFavourite: 是否收藏
    ///   - tags: 用户自定义标签
    ///   - isProtected: 是否为受保护条目（自动清理不淘汰）
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        textContent: String,
        ocrConfidence: Float,
        captureMode: String,
        sourceType: HistorySourceType = .screenshot,
        sourceAppName: String? = nil,
        sourceWindowTitle: String? = nil,
        imagePath: URL? = nil,
        thumbnailPath: URL? = nil,
        isFavourite: Bool = false,
        tags: [String] = [],
        isProtected: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.textContent = textContent
        self.ocrConfidence = ocrConfidence
        self.captureMode = captureMode
        self.sourceType = sourceType
        self.sourceAppName = sourceAppName
        self.sourceWindowTitle = sourceWindowTitle
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.isFavourite = isFavourite
        self.tags = tags
        self.isProtected = isProtected
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, textContent, ocrConfidence, captureMode
        case sourceType, sourceAppName, sourceWindowTitle
        case imagePath, thumbnailPath, isFavourite, tags
        case imageRevision, isProtected
    }

    /// 自定义解码以兼容不含 `isProtected` 键的旧记录。
    ///
    /// 合成的 `Codable` 实现要求所有非可选字段存在，新增的 `isProtected`
    /// 会令全部既有历史记录解码失败。此处显式解码并以 `false` 兜底。
    /// 编码仍使用合成实现。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        textContent = try container.decode(String.self, forKey: .textContent)
        ocrConfidence = try container.decode(Float.self, forKey: .ocrConfidence)
        captureMode = try container.decode(String.self, forKey: .captureMode)
        sourceType = try container.decode(HistorySourceType.self, forKey: .sourceType)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceWindowTitle = try container.decodeIfPresent(String.self, forKey: .sourceWindowTitle)
        imagePath = try container.decodeIfPresent(URL.self, forKey: .imagePath)
        thumbnailPath = try container.decodeIfPresent(URL.self, forKey: .thumbnailPath)
        isFavourite = try container.decode(Bool.self, forKey: .isFavourite)
        tags = try container.decode([String].self, forKey: .tags)
        imageRevision = try container.decodeIfPresent(UUID.self, forKey: .imageRevision)
        isProtected = try container.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
    }
}
