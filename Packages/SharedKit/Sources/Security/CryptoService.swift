import CryptoKit
import Foundation

/// AES-GCM 加密服务
///
/// 负责历史数据的加密存储与解密读取。使用 CryptoKit 提供的 AES-256-GCM 算法，
/// 密钥通过 `LocalKeyStore` 保存在应用支持目录的权限保护文件中。
///
/// **设计为 struct（无状态工具）而非 actor**：避免多个 actor 互相调用时产生嵌套死锁风险（R14）。
/// 所有加解密操作均为同步方法，由调用方（如 `HistoryCore`）在其 actor 边界内序列化调用。
///
/// 使用示例:
/// ```swift
/// let crypto = try CryptoService()
/// let encrypted = try crypto.encrypt(plainData)
/// let decrypted = try crypto.decrypt(encrypted)
/// ```
public struct CryptoService: Sendable {
    /// AES-256 对称密钥
    private let key: SymmetricKey

    /// 初始化加密服务
    ///
    /// 从应用本地密钥文件获取或创建加密密钥。
    ///
    /// - Parameter keyURL: 256-bit 密钥文件位置。
    /// - Throws: 当目录或密钥文件不可读写，或密钥数据无效时抛出错误。
    public init(
        keyURL: URL = URL.appSupportDirectory
            .appendingPathComponent("Security")
            .appendingPathComponent("history-v2.key")
    ) throws {
        self.key = try LocalKeyStore.loadOrCreateKey(at: keyURL)
    }

    /// 加密数据
    ///
    /// 使用 AES-GCM 对原始数据进行加密，返回包含 nonce、密文和认证标签的组合数据。
    ///
    /// - Parameter data: 待加密的原始数据（明文）。
    /// - Returns: AES-GCM 加密后的组合数据（nonce + ciphertext + tag）。
    /// - Throws: `AppError.encryptionFailed` 当加密过程发生错误时。
    public func encrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw AppError.encryptionFailed(reason: "AES-GCM 无法生成组合加密数据")
            }
            return combined
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.encryptionFailed(reason: error.localizedDescription)
        }
    }

    /// 解密数据
    ///
    /// 从 AES-GCM 组合数据中提取 nonce、密文和认证标签，验证完整性后解密。
    ///
    /// - Parameter data: AES-GCM 加密的组合数据（nonce + ciphertext + tag）。
    /// - Returns: 解密后的原始数据（明文）。
    /// - Throws: `AppError.decryptionFailed` 当数据完整性校验失败或解密错误时。
    public func decrypt(_ data: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decryptionFailed(reason: error.localizedDescription)
        }
    }
}
