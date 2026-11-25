import Foundation

/// A process-wide localization hook for the library package.
///
/// The App target owns language selection and injects its lookup here. The
/// headless CLI leaves the passthrough provider in place, so the same services
/// stay testable without importing any AppKit/UI code.
public enum LibraryLocalization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: @Sendable (String) -> String = { $0 }

    public static func setProvider(_ provider: @escaping @Sendable (String) -> String) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    public static func string(_ key: String) -> String {
        lock.lock()
        let provider = self.provider
        lock.unlock()
        return provider(key)
    }

    public static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
