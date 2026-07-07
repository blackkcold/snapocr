import Foundation

// MARK: - Foundation 扩展
// 共享的 Foundation 类型扩展，供各模块使用

// MARK: - Data 扩展

extension Data {

    /// 安全清零内存中的敏感数据
    /// 使用后确保敏感数据（如 OCR 识别结果）不被残留在内存中
    public mutating func zeroize() {
        let count = self.count
        self.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            memset_s(baseAddress, count, 0, count)
        }
    }
}

// MARK: - UserDefaults 扩展

/// 属性包装器，简化 UserDefaults 读写
@propertyWrapper
public struct UserDefault<T: Sendable>: Sendable {
    public let key: String
    public let defaultValue: T

    public init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    public var wrappedValue: T {
        get {
            UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

// MARK: - URL 扩展

extension URL {

    /// 应用支持目录 (Application Support)
    public static var appSupportDirectory: URL {
        let paths = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        return paths[0].appendingPathComponent("SnapGlass")
    }

    /// 确保目录存在
    public func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: self,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
