import Foundation

/// 更新清单的 JSON 解码结构。
struct UpdateManifest: Decodable {
    let schemaVersion: Int
    let version: String
    let releaseNotes: String
    let releasePageURL: URL
    let dmgURL: URL
    let checksumURL: URL
    let assetName: String
    let sha256: String
}
