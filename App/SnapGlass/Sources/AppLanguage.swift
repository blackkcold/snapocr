import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese
    case japanese
    case korean

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            .current
        case .english:
            Locale(identifier: "en")
        case .simplifiedChinese:
            Locale(identifier: "zh-Hans")
        case .japanese:
            Locale(identifier: "ja")
        case .korean:
            Locale(identifier: "ko")
        }
    }

    /// The `.lproj` identifier, or `nil` when the OS should choose.
    var resourceIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }
}
