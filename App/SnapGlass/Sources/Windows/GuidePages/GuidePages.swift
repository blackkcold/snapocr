import AppKit
import KeyboardShortcuts
import SharedKit
import SwiftUI

/// Page 1: where the app actually lives.
///
/// This is the page that answers "I double-clicked and nothing happened". It must
/// place the icon in the menu bar visually, because telling someone to "look in
/// the menu bar" fails on a display with twenty menu-bar items.
struct LocationPage: View {
    /// Whether the Dock icon stays permanently.
    @Binding var keepInDock: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s18) {
            GuidePageHeader(
                title: "SnapGlass lives in the menu bar.",
                subtitle: "Look for the camera icon on the right, near the clock."
            )

            MenuBarDiagram()
                .frame(maxWidth: .infinity)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: DS.Space.s8) {
                    Text("If your menu bar is crowded, macOS may hide the icon in the overflow area.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        openControlCenterSettings()
                    } label: {
                        Label("Open Control Center Settings", systemImage: "switch.2")
                            .font(DS.Typography.captionStrong)
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, DS.Space.s6)
            } label: {
                Text("I don't see it")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Toggle(isOn: $keepInDock) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep SnapGlass in the Dock")
                        .font(DS.Typography.body)
                    Text("The Dock icon shows whether the app is running.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private func openControlCenterSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Page 3: what happens after a capture.
struct CapturePage: View {
    /// Called when the user asks to try a capture.
    let onTryCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s16) {
            GuidePageHeader(
                title: "Every capture waits in the shelf.",
                subtitle: "Nothing is lost, and nothing opens on top of your work."
            )

            CaptureFlowDiagram()
                .frame(maxWidth: .infinity)

            Text(
                "SnapGlass does not open a window for every screenshot. The shelf holds your recent "
                    + "captures and disappears when you stop using it."
            )
            .font(DS.Typography.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: onTryCapture) {
                Label("Try a capture", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

/// Page 4: recording and the permission it needs.
struct RecordPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s16) {
            GuidePageHeader(
                title: "Screen and audio recording.",
                subtitle: "Start a recording from the menu bar. The controls follow you across displays."
            )

            RecordingDiagram()
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: DS.Space.s8) {
                Label {
                    Text("Screen Recording permission is needed the first time you record a screen.")
                        .font(DS.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                Text("macOS asks once. SnapGlass never records before you press record.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: DS.Corner.c10))

            Spacer(minLength: 0)
        }
    }
}

/// Shared page heading.
struct GuidePageHeader: View {
    /// Localization key for the page title.
    let title: String
    /// Localization key for the page subtitle.
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            Text(LocalizedStringKey(title))
                .font(.system(size: DS.Typography.t20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey(subtitle))
                .font(DS.Typography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
