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

                    PreferencesCardCaption(text: LocalizedStringKey(copyright))
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

    private var copyright: String {
        String(localized: "Copyright © SnapGlass Contributors. Released under the MIT License.")
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

                    if viewModel.isCheckingForUpdates {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking for Updates...")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else if viewModel.isDownloadingUpdate {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading Update...")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Check for Updates...") {
                            viewModel.checkForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    PreferencesCardCaption(text: "Updates are downloaded from the GitHub Releases page and verified with SHA-256 before saving.")
                }
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
