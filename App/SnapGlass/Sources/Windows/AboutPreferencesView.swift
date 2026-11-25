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
    @EnvironmentObject private var updater: UpdaterManager

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                PreferencesCard {
                    PreferencesCardHeader(systemImage: "arrow.down.circle", title: "Update") {
                        Text(verbatim: versionLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }

                    stateContent

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Automatically check for updates", isOn: autoCheckBinding)
                        Toggle("Automatically download and install updates", isOn: autoDownloadBinding)
                            .disabled(!updater.automaticallyChecksForUpdates || !updater.allowsAutomaticUpdates)
                    }

                    Divider()

                    PreferencesCardCaption(text: footnote)
                }
            }
        }
    }

    // MARK: State

    @ViewBuilder
    private var stateContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let blocker = updater.pendingBlocker {
                pendingBanner(blocker)
            }

            switch updater.state {
            case .idle:
                Text("Check for updates from GitHub Releases.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)

            case .checking:
                statusHeader(
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .accentColor,
                    title: AppLocalization.string("Checking for Updates...")
                ) {
                    ProgressView()
                        .controlSize(.small)
                }

            case .upToDate(let version):
                statusHeader(
                    systemImage: "checkmark.seal.fill",
                    tint: .green,
                    title: AppLocalization.string("SnapGlass is Up to Date"),
                    detail: AppLocalization.string(
                        "You are running the latest version (%@).",
                        version
                    )
                )

                Button("Check Again") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)

            case .available(let update):
                statusHeader(
                    systemImage: update.isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill",
                    tint: update.isDownloaded ? .green : .accentColor,
                    title: update.isDownloaded
                        ? AppLocalization.string("Update Ready to Install")
                        : AppLocalization.string("SnapGlass %@ is Available", update.displayVersion),
                    detail: update.isDownloaded
                        ? AppLocalization.string(
                            "SnapGlass %@ has been downloaded and verified.",
                            update.displayVersion
                        )
                        : AppLocalization.string("A new version is ready to download.")
                )

                HStack(spacing: 10) {
                    if update.isDownloaded {
                        Button("Install and Relaunch...") {
                            updater.presentUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Download and Install...") {
                            updater.presentUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let notesURL = update.releaseNotesURL {
                        Button("Release Notes") {
                            NSWorkspace.shared.open(notesURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }

            case .failed(let message):
                statusHeader(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: AppLocalization.string("Unable to Check for Updates"),
                    detail: message
                )

                Button("Try Again") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func pendingBanner(_ blocker: UpdateBlocker) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: blocker == .recording ? "record.circle" : "square.and.pencil")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)

            Text(LocalizedStringKey(blocker.message))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
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

    // MARK: Bindings

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private var autoDownloadBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.automaticallyDownloadsUpdates = $0 }
        )
    }

    private var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    private var footnote: LocalizedStringKey {
        "Updates are downloaded from the GitHub Releases page and verified with Sparkle's EdDSA signature."
    }
}
