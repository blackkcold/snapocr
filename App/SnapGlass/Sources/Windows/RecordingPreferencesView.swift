import AppKit
import SharedKit
import SwiftUI

struct RecordingPreferencesView: View {
    @AppStorage(PreferenceKeys.recordingVideoCodec)
    private var videoCodec = PreferenceDefaults.recordingVideoCodec
    @AppStorage(PreferenceKeys.recordingResolution)
    private var resolution = PreferenceDefaults.recordingResolution
    @AppStorage(PreferenceKeys.recordingFrameRate)
    private var frameRate = PreferenceDefaults.recordingFrameRate
    @AppStorage(PreferenceKeys.recordingAverageVideoBitrate)
    private var averageVideoBitrate = PreferenceDefaults.recordingAverageVideoBitrate
    @AppStorage(PreferenceKeys.recordingSystemAudio)
    private var systemAudio = PreferenceDefaults.recordingSystemAudio
    @AppStorage(PreferenceKeys.recordingHUDOpacity)
    private var hudOpacity = PreferenceDefaults.recordingHUDOpacity
    @AppStorage(PreferenceKeys.recordingHUDHoverRestore)
    private var hudHoverRestore = PreferenceDefaults.recordingHUDHoverRestore
    @AppStorage(PreferenceKeys.recordingHUDHidden)
    private var hudHidden = PreferenceDefaults.recordingHUDHidden
    @AppStorage(PreferenceKeys.recordingShowCaptureFrame)
    private var showCaptureFrame = PreferenceDefaults.recordingShowCaptureFrame
    @AppStorage(PreferenceKeys.recordingRevealOnFinish)
    private var revealOnFinish = PreferenceDefaults.recordingRevealOnFinish
    @AppStorage(PreferenceKeys.recordingCustomOutputDirectory)
    private var customOutputDirectoryPath = ""
    @State private var availableSpace: Int64?

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                videoCard
                controlPanelCard
                destinationCard
            }
        }
        .onAppear(perform: refreshAvailableSpace)
    }

    private var videoCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "record.circle", title: "Video")

            Picker("Codec", selection: videoCodecBinding) {
                Text("H.264").tag("h264")
                Text("HEVC").tag("hevc")
            }
            .pickerStyle(.menu)

            Picker("Resolution limit", selection: $resolution) {
                Text("720p").tag("720p")
                Text("1080p").tag("1080p")
                Text("1440p").tag("1440p")
                Text("2160p").tag("2160p")
                Text("Source size").tag("source")
            }
            .pickerStyle(.menu)

            Picker("Frame rate", selection: $frameRate) {
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.menu)

            Picker("Average video bitrate", selection: $averageVideoBitrate) {
                Text("2 Mbps").tag(2_000_000)
                Text("4 Mbps").tag(4_000_000)
                Text("8 Mbps").tag(8_000_000)
                Text("12 Mbps").tag(12_000_000)
                Text("16 Mbps").tag(16_000_000)
                Text("20 Mbps").tag(20_000_000)
            }
            .pickerStyle(.menu)

            Toggle("Include system audio", isOn: $systemAudio)

            PreferencesCardCaption(
                text: "HEVC typically uses half the H.264 bitrate for a similar quality target."
            )
            PreferencesCardCaption(text: "Estimated size per minute: \(estimatedSize)")
        }
    }

    private var controlPanelCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "rectangle.inset.filled", title: "Control panel")

            HStack(spacing: 10) {
                Text("Panel opacity")
                Slider(value: hudOpacityBinding, in: RecordingHUDPreferences.opacityRange, step: 0.05)
                Text("\(Int((hudOpacity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .disabled(hudHidden)

            Toggle("Restore full opacity while hovering", isOn: $hudHoverRestore)
                .disabled(hudHidden)
            Toggle("Hide the floating panel during recordings", isOn: $hudHidden)
            Toggle("Show a frame around the captured area", isOn: $showCaptureFrame)
            Toggle("Reveal in Finder when a recording finishes", isOn: $revealOnFinish)

            PreferencesCardCaption(
                text: "The panel never covers the captured area; drag it to another corner at any time."
            )
        }
    }

    private var hudOpacityBinding: Binding<Double> {
        Binding(
            get: { hudOpacity },
            set: { newValue in
                hudOpacity = min(max(newValue, RecordingHUDPreferences.opacityRange.lowerBound), 1)
            }
        )
    }

    private var destinationCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "folder", title: "Destination")

            VStack(alignment: .leading, spacing: 6) {
                Text(destinationDescription)
                    .font(.callout)
                    .foregroundStyle(destinationUnavailable ? .red : .secondary)
                    .textSelection(.enabled)

                if let availableSpace {
                    Text("Available space: \(RecordingStorage.formattedBytes(availableSpace))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !hasCustomDestination {
                    Text("The default folder will be created when recording starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Choose Folder…", action: chooseDirectory)
                    .buttonStyle(.borderedProminent)

                Button("Open Folder", action: openDirectory)
                    .disabled(!directoryExists)

                Button("Reset to Default", action: resetDirectory)
                    .disabled(!hasCustomDestination)
            }

            PreferencesCardCaption(
                text: "Changing the destination does not move existing recordings or create this folder."
            )
        }
        .onChange(of: customOutputDirectoryPath) { _ in
            refreshAvailableSpace()
        }
    }

    private var videoCodecBinding: Binding<String> {
        Binding(
            get: { videoCodec },
            set: { newCodec in
                let previousDefaultBitrate = videoCodec == "hevc" ? 4_000_000 : 8_000_000
                let newDefaultBitrate = newCodec == "hevc" ? 4_000_000 : 8_000_000
                if averageVideoBitrate == previousDefaultBitrate {
                    averageVideoBitrate = newDefaultBitrate
                }
                videoCodec = newCodec
            }
        )
    }

    private var hasCustomDestination: Bool {
        !customOutputDirectoryPath.isEmpty
    }

    private var directory: URL? {
        RecordingDestinationPreferences.directory()
    }

    private var directoryExists: Bool {
        guard let directory else { return false }
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var destinationUnavailable: Bool {
        hasCustomDestination && !directoryExists
    }

    private var destinationDescription: String {
        if let customDirectory = RecordingDestinationPreferences.customDirectory() {
            return customDirectory.path
        }
        return "Movies/SnapGlass/Recordings"
    }

    private var estimatedSize: String {
        let audioBitrate = systemAudio ? 128_000 : 0
        let estimatedBytes = Int64(averageVideoBitrate + audioBitrate) * 60 / 8
        return RecordingStorage.formattedBytes(estimatedBytes)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = AppLocalization.string("Choose a folder for new screen recordings")
        panel.prompt = AppLocalization.string("Choose Folder")

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        RecordingDestinationPreferences.setCustomDirectory(selectedURL)
        customOutputDirectoryPath = selectedURL.standardizedFileURL.path
        refreshAvailableSpace()
    }

    private func openDirectory() {
        guard directoryExists, let directory else { return }
        NSWorkspace.shared.open(directory)
    }

    private func resetDirectory() {
        RecordingDestinationPreferences.reset()
        customOutputDirectoryPath = ""
        refreshAvailableSpace()
    }

    private func refreshAvailableSpace() {
        guard let directory else {
            availableSpace = nil
            return
        }
        availableSpace = RecordingStorage.availableBytes(at: directory)
    }
}
