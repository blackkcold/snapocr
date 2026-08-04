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
}
