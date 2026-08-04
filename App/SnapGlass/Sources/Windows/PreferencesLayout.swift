import SwiftUI

enum PreferencesSpacing {
    static let cardGap: CGFloat = 16
    static let pagePadding: CGFloat = 20
    static let cardPadding: CGFloat = 14
    static let rowGap: CGFloat = 12
    static let cornerRadius: CGFloat = 14
    static let minCardWidth: CGFloat = 340

    // MARK: - Responsive window sizing
    static let minWindowWidth: CGFloat = 660
    static let minWindowHeight: CGFloat = 520
    static let idealWindowWidth: CGFloat = 900
    static let idealWindowHeight: CGFloat = 620
    static let minWindowCornerRadius: CGFloat = 14
    static let maxWindowCornerRadius: CGFloat = 30
    static let cornerRadiusReferenceWidth: CGFloat = 1400

    static func resolvedWindowCornerRadius(forWidth width: CGFloat) -> CGFloat {
        let clampedWidth = min(max(width, minWindowWidth), cornerRadiusReferenceWidth)
        let progress = (clampedWidth - minWindowWidth) / (cornerRadiusReferenceWidth - minWindowWidth)
        return minWindowCornerRadius + (maxWindowCornerRadius - minWindowCornerRadius) * progress
    }
}

struct PreferencesCardGrid<Content: View>: View {
    var spacing: CGFloat = PreferencesSpacing.cardGap
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: PreferencesSpacing.minCardWidth, maximum: .infinity), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            content
        }
        .padding(PreferencesSpacing.pagePadding)
    }
}

struct PreferencesCard<Content: View>: View {
    var cornerRadius: CGFloat = PreferencesSpacing.cornerRadius
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesSpacing.rowGap) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PreferencesSpacing.cardPadding)
        .glassSurface(in: .concentric(minimumRadius: cornerRadius))
    }
}

struct PreferencesCardHeader<Accessory: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder var accessory: Accessory

    init(systemImage: String, title: String, @ViewBuilder accessory: () -> Accessory) {
        self.systemImage = systemImage
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension PreferencesCardHeader where Accessory == EmptyView {
    init(systemImage: String, title: String) {
        self.init(systemImage: systemImage, title: title) { EmptyView() }
    }
}

struct PreferencesCardCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
