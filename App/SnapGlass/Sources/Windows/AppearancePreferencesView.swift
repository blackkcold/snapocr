import SharedKit
import SwiftUI

struct AppearancePreferencesView: View {
    @AppStorage(PreferenceKeys.appearanceMode)
    private var appearanceMode = PreferenceDefaults.appearanceMode

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(AppearanceMode.allCases) { mode in
                        AppearanceOptionButton(
                            mode: mode,
                            isSelected: appearanceMode == mode.rawValue
                        ) {
                            appearanceMode = mode.rawValue
                        }
                    }
                }

                Text("Changes apply immediately to every SnapGlass window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Theme", systemImage: "paintpalette")
            }
        }
        .padding()
    }
}

private struct AppearanceOptionButton: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 48, height: 48)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                        in: Circle()
                    )

                Text(mode.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(12)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(mode.title))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
    }
}

private extension AppearanceMode {
    var title: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .system: "Match the current macOS appearance."
        case .light: "Always use the light appearance."
        case .dark: "Always use the dark appearance."
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}
