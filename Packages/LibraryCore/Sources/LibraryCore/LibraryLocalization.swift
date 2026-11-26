import Foundation

/// A process-wide localization hook for the library package.
///
/// The App target owns language selection and injects its lookup here. The
/// headless CLI leaves the passthrough provider in place, so the same services
/// stay testable without importing any AppKit/UI code.
public enum LibraryLocalization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: @Sendable (String) -> String = { $0 }

    /// Installs the lookup used for every later `string(_:)` call.
    ///
    /// - Parameter provider: Function that maps a key to its localized text.
    public static func setProvider(_ provider: @escaping @Sendable (String) -> String) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    /// Returns the localized text for a key, or the key itself when no provider
    /// is installed.
    ///
    /// - Parameter key: Localization key.
    /// - Returns: Localized text for `key`.
    public static func string(_ key: String) -> String {
        lock.lock()
        let provider = self.provider
        lock.unlock()
        return provider(key)
    }

    /// Returns the localized text for a key with positional format arguments
    /// substituted.
    ///
    /// - Parameters:
    ///   - key: Localization key.
    ///   - arguments: Values substituted into the format string.
    /// - Returns: Formatted localized text.
    public static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
