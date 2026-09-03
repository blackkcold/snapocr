import SharedKit
import SwiftUI

// MARK: - Developer Preferences

struct DeveloperPreferencesView: View {
    @AppStorage(PreferenceKeys.developerMode)
    private var devMode = PreferenceDefaults.developerMode
    @AppStorage(PreferenceKeys.engineComparison)
    private var engineComparison = PreferenceDefaults.engineComparison
    @AppStorage(PreferenceKeys.forceUpdateAvailable)
    private var forceUpdateAvailable = PreferenceDefaults.forceUpdateAvailable

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                PreferencesCard {
                    PreferencesCardHeader(systemImage: "hammer", title: "Developer Mode") {
                        statusBadge(enabled: devMode)
                    }
                    Toggle("Enable Developer Mode", isOn: $devMode)
                }

                if devMode {
                    PreferencesCard {
                        PreferencesCardHeader(systemImage: "gearshape.2", title: "Diagnostics")

                        Toggle("Enable Engine Comparison", isOn: $engineComparison)
                        Toggle("Force Latest Release as Update", isOn: $forceUpdateAvailable)

                        PreferencesCardCaption(text: LocalizedStringKey(
                            "When enabled, Check for Updates shows the latest GitHub Release "
                                + "even if its version is not newer."
                        ))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(enabled: Bool) -> some View {
        Label(enabled ? "On" : "Off", systemImage: enabled ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(enabled ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(enabled ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1), in: Capsule())
    }
}

/// A selectable OCR recognition language. `code` is the compact identifier
/// stored in `ocrEnabledLanguages`; Vision resolves it to its full identifier.
enum OCRLanguageOption: String, CaseIterable, Identifiable {
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case korean

    var id: String { code }

    var code: String {
        switch self {
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .japanese: return "ja"
        case .korean: return "ko"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }
}
