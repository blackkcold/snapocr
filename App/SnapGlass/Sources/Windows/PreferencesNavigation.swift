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
    var collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Group {
            if collapsed {
                Button(action: onToggle) {
                    logoView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Expand sidebar")
                .accessibilityLabel(Text("Expand sidebar"))
            } else {
                HStack(spacing: 10) {
                    logoView

                    VStack(alignment: .leading, spacing: 1) {
                        Text("SnapGlass")
                            .font(.headline)
                        Text("Preferences")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Button(action: onToggle) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Collapse sidebar")
                }
            }
        }
        .padding(.horizontal, collapsed ? 0 : 12)
        .padding(.vertical, 12)
    }

    private var logoView: some View {
        Image(systemName: "camera.viewfinder")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 32, height: 32)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct PreferencesSidebarLabel: View {
    let section: PreferencesSection
    var isSelected: Bool
    var collapsed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    isSelected ? Color.accentColor.opacity(0.12) : Color.accentColor.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7)
                )

            if !collapsed {
                Text(section.title)
                    .lineLimit(1)
                    .font(.body)

                Spacer(minLength: 0)
            }
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
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .zIndex(1)
    }
}
