import AppKit
import SwiftUI
import SharedKit

// MARK: - About

struct AboutPreferencesView: View {
    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                PreferencesCard {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 84, height: 84)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))

                        VStack(spacing: 4) {
                            Text("SnapGlass")
                                .font(.title2.weight(.semibold))
                            Text(appVersion)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

                        Text("Offline-first, privacy-first macOS screenshot and OCR tool.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Divider()

                        Button("View on GitHub") {
                            openGitHub()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                PreferencesCard {
                    PreferencesCardHeader(systemImage: "checkmark.seal", title: "Version")

                    LabeledContent("App version") {
                        Text(appVersion)
                            .monospacedDigit()
                    }
                    LabeledContent("Build") {
                        Text(appBuild)
                            .monospacedDigit()
                    }

                    PreferencesCardCaption(text: copyright)
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private var copyright: LocalizedStringKey {
        "Copyright © SnapGlass Contributors. Released under the MIT License."
    }

    private func openGitHub() {
        guard let url = URL(string: "https://github.com/blackkcold/snapocr") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Updates

struct UpdatesPreferencesView: View {
    @EnvironmentObject private var viewModel: CaptureViewModel

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                PreferencesCard {
                    PreferencesCardHeader(systemImage: "arrow.down.circle", title: "Update")

                    LabeledContent("Current version") {
                        Text(currentVersion)
                            .monospacedDigit()
                    }

                    Divider()

                    stateContent

                    Divider()

                    footnote
                }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.updateCheckState {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                Text("Check GitHub Releases for a newer version.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Check for Updates...") {
                    viewModel.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }

        case .checking:
            statusHeader(
                systemImage: "arrow.triangle.2.circlepath",
                tint: .accentColor,
                title: AppLocalization.string("Checking for Updates...")
            ) {
                ProgressView()
                    .controlSize(.small)
            }

        case .upToDate(let latestVersion):
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    systemImage: "checkmark.seal.fill",
                    tint: .green,
                    title: AppLocalization.string("SnapGlass is Up to Date"),
                    detail: AppLocalization.string(
                        "You are running the latest version (%@).",
                        latestVersion.description
                    )
                )

                Button("Check Again") {
                    viewModel.checkForUpdates()
                }
                .buttonStyle(.bordered)
            }

        case .available(let release):
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    systemImage: "arrow.down.circle.fill",
                    tint: .accentColor,
                    title: AppLocalization.string("SnapGlass %@ is Available", release.tagName),
                    detail: AppLocalization.string("A new version is ready to download.")
                )

                releaseNotes(for: release)

                HStack(spacing: 10) {
                    Button("Download Update") {
                        viewModel.downloadUpdate(release)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("View on GitHub") {
                        NSWorkspace.shared.open(release.releasePageURL)
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .downloading(let release):
            statusHeader(
                systemImage: "arrow.down.circle",
                tint: .accentColor,
                title: AppLocalization.string("Downloading Update..."),
                detail: AppLocalization.string(
                    "SnapGlass %@ is being downloaded and verified.",
                    release.tagName
                )
            ) {
                ProgressView()
                    .controlSize(.small)
            }

        case .readyToInstall(let release, let fileURL):
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    title: AppLocalization.string("Update Ready to Install"),
                    detail: AppLocalization.string(
                        "SnapGlass %@ has been downloaded and verified.",
                        release.tagName
                    )
                )

                HStack(spacing: 10) {
                    Button("Open Installer") {
                        viewModel.installDownloadedUpdate(release, at: fileURL)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .checkFailed(let message):
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: AppLocalization.string("Unable to Check for Updates"),
                    detail: message
                )

                Button("Try Again") {
                    viewModel.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }

        case .downloadFailed(let release, let message):
            VStack(alignment: .leading, spacing: 12) {
                statusHeader(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: AppLocalization.string("Update Download Failed"),
                    detail: message
                )

                HStack(spacing: 10) {
                    Button("Try Again") {
                        viewModel.downloadUpdate(release)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("View on GitHub") {
                        NSWorkspace.shared.open(release.releasePageURL)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func statusHeader(
        systemImage: String,
        tint: Color,
        title: String,
        detail: String? = nil
    ) -> some View {
        statusHeader(
            systemImage: systemImage,
            tint: tint,
            title: title,
            detail: detail
        ) {
            EmptyView()
        }
    }

    private func statusHeader<Accessory: View>(
        systemImage: String,
        tint: Color,
        title: String,
        detail: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(
                    tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            accessory()
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func releaseNotes(for release: UpdateRelease) -> some View {
        let notes = release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What's New")
                    .font(.subheadline.weight(.semibold))

                Text(String(notes.prefix(1_500)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if case .readyToInstall = viewModel.updateCheckState {
            PreferencesCardCaption(text: LocalizedStringKey(
                "SnapGlass will quit after opening the installer. Save your work first."
            ))
        } else {
            PreferencesCardCaption(text: LocalizedStringKey(
                "Updates are downloaded from the GitHub Releases page "
                    + "and verified with SHA-256 before saving."
            ))
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
