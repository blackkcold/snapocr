import CryptoKit
import Foundation
import Security

/// Keychain 存取服务
///
/// 负责加密密钥的安全存储与读取。
/// 所有方法均为静态且同步，设计为无状态工具类型，避免 actor 嵌套死锁风险。
///
/// 密钥存储在系统钥匙串中，使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// 确保设备锁定时无法读取，且不会随 iCloud 备份同步。
public struct KeychainService: Sendable {

    /// Keychain 服务名称，用于隔离应用数据
    private static let service = "com.snapglass"

    // MARK: - 密钥管理

    /// 从 Keychain 获取或创建加密密钥
    ///
    /// 优先尝试从 Keychain 读取已有密钥；若不存在则生成新密钥并持久化存储。
    ///
    /// - Parameter identifier: 密钥的唯一标识符，如 `"com.snapglass.history.encryption"`。
    /// - Returns: 用于 AES-GCM 加密的 `SymmetricKey`。
    /// - Throws: `AppError.keychainAccessFailed` 当 Keychain 访问失败时。
    public static func getOrCreateKey(identifier: String) throws -> SymmetricKey {
        if let existingData = try retrieve(identifier: identifier) {
            return SymmetricKey(data: existingData)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try store(keyData, identifier: identifier)
        return newKey
    }

    // MARK: - 基本操作

    /// 存储数据到 Keychain
    ///
    /// 如果该标识符已存在数据，则先删除再写入（覆盖更新）。
    ///
    /// - Parameters:
    ///   - data: 待存储的二进制数据。
    ///   - identifier: 唯一标识符。
    /// - Throws: `AppError.keychainAccessFailed` 当 Keychain 写入失败时。
    public static func store(_ data: Data, identifier: String) throws {
        // 如果已存在，先删除
        try? delete(identifier: identifier)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.keychainAccessFailed(status: status)
        }
    }

    /// 从 Keychain 读取数据
    ///
    /// - Parameter identifier: 唯一标识符。
    /// - Returns: 存储的数据，不存在时返回 `nil`。
    /// - Throws: `AppError.keychainAccessFailed` 当 Keychain 读取失败时（条目不存在不视为错误）。
    public static func retrieve(identifier: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.keychainAccessFailed(status: status)
        }
    }

    /// 从 Keychain 删除数据
    ///
    /// - Parameter identifier: 唯一标识符。
    /// - Throws: `AppError.keychainAccessFailed` 当 Keychain 删除失败时。
    public static func delete(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.keychainAccessFailed(status: status)
        }
    }
}
