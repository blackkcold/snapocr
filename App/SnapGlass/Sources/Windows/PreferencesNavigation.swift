import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case capture
    case ocr
    case shortcuts
    case history
    case developer

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .capture: "Capture"
        case .ocr: "OCR"
        case .shortcuts: "Shortcuts"
        case .history: "History"
        case .developer: "Developer"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .general: "Language, startup, and everyday behaviour."
        case .appearance: "Choose how SnapGlass looks across every window."
        case .capture: "Control capture behaviour and image output."
        case .ocr: "Tune recognition accuracy and language priority."
        case .shortcuts: "Customize global keyboard shortcuts."
        case .history: "Manage encrypted history, retention, and storage."
        case .developer: "Configure diagnostics and update testing."
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .capture: "camera.viewfinder"
        case .ocr: "text.viewfinder"
        case .shortcuts: "keyboard"
        case .history: "clock.arrow.circlepath"
        case .developer: "hammer"
        }
    }
}

struct PreferencesSidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 1) {
                Text("SnapGlass")
                    .font(.headline)
                Text("Preferences")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct PreferencesSidebarLabel: View {
    let section: PreferencesSection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

            Text(section.title)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct PreferencesPageHeader: View {
    let section: PreferencesSection

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                Text(section.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
