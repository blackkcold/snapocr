import CryptoKit
import Foundation

/// App-local AES key storage that never accesses the system Keychain.
///
/// The key file is protected with owner-only POSIX permissions. This protects
/// encrypted history from casual file inspection but does not defend against an
/// attacker who already controls the current macOS user account.
public enum LocalKeyStore {
  private static let lock = NSLock()
  private static let keyByteCount = 32

  /// Loads an existing 256-bit key or creates one at the specified URL.
  public static func loadOrCreateKey(at keyURL: URL) throws -> SymmetricKey {
    lock.lock()
    defer { lock.unlock() }

    let fileManager = FileManager.default
    let directory = keyURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    if fileManager.fileExists(atPath: keyURL.path) {
      let data = try Data(contentsOf: keyURL)
      guard data.count == keyByteCount else {
        throw AppError.decryptionFailed(reason: "本地历史密钥长度无效")
      }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
      return SymmetricKey(data: data)
    }

    let key = SymmetricKey(size: .bits256)
    let data = key.withUnsafeBytes { Data($0) }
    try data.write(to: keyURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    return key
  }
}
