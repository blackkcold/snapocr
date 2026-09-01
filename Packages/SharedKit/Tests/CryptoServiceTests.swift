import CryptoKit
import Foundation
import Testing
@testable import SharedKit

struct CryptoServiceTests {
    /// 每个测试使用独立临时目录，避免污染真实 Application Support。
    private func makeTempKeyURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapGlassCryptoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history-v2.key")
    }

    @Test func encryptDecryptRoundTrip() throws {
        let keyURL = try makeTempKeyURL()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let crypto = try CryptoService(keyURL: keyURL)
        let plaintext = Data("SnapGlass 加密 round-trip 测试 🔐".utf8)

        let encrypted = try crypto.encrypt(plaintext)
        #expect(encrypted != plaintext)
        #expect(!encrypted.isEmpty)

        let decrypted = try crypto.decrypt(encrypted)
        #expect(decrypted == plaintext)
    }

    @Test func encryptProducesDifferentCiphertextForSamePlaintext() throws {
        let keyURL = try makeTempKeyURL()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let crypto = try CryptoService(keyURL: keyURL)
        let plaintext = Data("same input".utf8)

        // AES-GCM 每次使用随机 nonce，同明文应产生不同密文
        let a = try crypto.encrypt(plaintext)
        let b = try crypto.encrypt(plaintext)
        #expect(a != b)
        #expect(try crypto.decrypt(a) == plaintext)
        #expect(try crypto.decrypt(b) == plaintext)
    }

    @Test func decryptWithWrongKeyFails() throws {
        let keyURL1 = try makeTempKeyURL()
        let keyURL2 = try makeTempKeyURL()
        defer {
            try? FileManager.default.removeItem(at: keyURL1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: keyURL2.deletingLastPathComponent())
        }

        let crypto1 = try CryptoService(keyURL: keyURL1)
        let crypto2 = try CryptoService(keyURL: keyURL2)

        let encrypted = try crypto1.encrypt(Data("secret".utf8))
        #expect(throws: AppError.self) {
            _ = try crypto2.decrypt(encrypted)
        }
    }

    @Test func decryptTamperedDataFails() throws {
        let keyURL = try makeTempKeyURL()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let crypto = try CryptoService(keyURL: keyURL)
        var encrypted = try crypto.encrypt(Data("integrity check".utf8))

        // 篡改密文中间字节，GCM 认证标签应校验失败
        let mid = encrypted.count / 2
        encrypted[mid] ^= 0xFF

        #expect(throws: AppError.self) {
            _ = try crypto.decrypt(encrypted)
        }
    }

    @Test func keyPersistsAcrossInstances() throws {
        let keyURL = try makeTempKeyURL()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        let first = try CryptoService(keyURL: keyURL)
        let encrypted = try first.encrypt(Data("persist".utf8))

        // 新实例应从同一密钥文件加载相同密钥并成功解密
        let second = try CryptoService(keyURL: keyURL)
        #expect(try second.decrypt(encrypted) == Data("persist".utf8))
    }
}

struct LocalKeyStoreExtendedTests {
    private func makeTempKeyURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapGlassKeyStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.key")
    }

    @Test func createsDirectoryWith0700Permissions() throws {
        let keyURL = try makeTempKeyURL()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        _ = try LocalKeyStore.loadOrCreateKey(at: keyURL)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: keyURL.deletingLastPathComponent().path)
        let dirPerms = dirAttrs[.posixPermissions] as? Int
        #expect(dirPerms == 0o700)
    }

    @Test func rejectsInvalidLengthKeyFile() throws {
        let keyURL = try makeTempKeyURL()
        defer { try? FileManager.default.removeItem(at: keyURL.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: keyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: 16).write(to: keyURL)

        #expect(throws: AppError.self) {
            _ = try LocalKeyStore.loadOrCreateKey(at: keyURL)
        }
    }
}
