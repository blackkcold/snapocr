import AppKit
import CaptureCore
import KeyboardShortcuts
import SharedKit
import SwiftUI

struct RecordingPreferencesView: View {
    @EnvironmentObject private var viewModel: CaptureViewModel
    @AppStorage(PreferenceKeys.recordingAudioMode)
    private var audioMode = PreferenceDefaults.recordingAudioMode
    @AppStorage(PreferenceKeys.recordingScreenAudioMode)
    private var screenAudioMode = PreferenceDefaults.recordingScreenAudioMode
    @AppStorage(PreferenceKeys.recordingOutputLayout)
    private var outputLayout = PreferenceDefaults.recordingOutputLayout
    @AppStorage(RecordingAudioPreferenceStore.audioBitRateKey)
    private var audioBitRate = 128_000
    @AppStorage(PreferenceKeys.recordingHideShelfWhileRecording)
    private var hideShelfWhileRecording = PreferenceDefaults.recordingHideShelfWhileRecording
    @AppStorage(PreferenceKeys.recordingMenuBarDuration)
    private var menuBarDuration = PreferenceDefaults.recordingMenuBarDuration
    @AppStorage(PreferenceKeys.recordingAudioShortcut)
    private var audioShortcut = PreferenceDefaults.recordingAudioShortcut
    @AppStorage(PreferenceKeys.recordingShortcutHintShown)
    private var recordingShortcutHintShown = PreferenceDefaults.recordingShortcutHintShown

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
    @State private var resolvedScreenAudioMode = PreferenceDefaults.recordingScreenAudioMode
    @State private var isShowingAudioShortcutHint = false
    @State private var availableSpace: Int64?

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                audioCard
                safetyCard
                destinationCard
            }
        }
        .onAppear(perform: preparePreferences)
        .alert("Audio Recording Shortcut", isPresented: $isShowingAudioShortcutHint) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("No audio-recording shortcut is assigned by default. Record one here if you want a global shortcut.")
        }
    }

    private var audioCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "waveform", title: "Audio")

            Picker("Audio-only recording", selection: $audioMode) {
                Text("System Audio").tag("system")
                Text("Microphone").tag("microphone")
                Text("System Audio + Microphone").tag("systemAndMicrophone")
            }
            .pickerStyle(.menu)

            Picker("Screen recording audio", selection: screenAudioModeBinding) {
                Text("System Audio").tag("system")
                Text("Microphone").tag("microphone")
                Text("System Audio + Microphone").tag("systemAndMicrophone")
                Text("No Audio").tag("none")
            }
            .pickerStyle(.menu)

            Picker("Audio track layout", selection: $outputLayout) {
                Text("Mixed Track").tag("mixed")
                Text("Separate Tracks").tag("separateTracks")
            }
            .pickerStyle(.menu)

            Picker("Audio quality", selection: $audioBitRate) {
                Text("Economy · 96 kbps").tag(96_000)
                Text("Standard · 128 kbps").tag(128_000)
                Text("High · 192 kbps").tag(192_000)
                Text("Maximum · 256 kbps").tag(256_000)
            }
            .pickerStyle(.menu)

            PreferencesCardCaption(
                text: "Selected AAC bitrate is applied to each encoded track."
            )

            PreferencesCardCaption(
                text: "Screen recordings still use the existing system-audio route; microphone routing will be applied with screen-audio integration."
            )

            Divider()

            HStack(spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio Recording Shortcut")
                        if audioShortcut.isEmpty {
                            Text("No shortcut assigned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "keyboard")
                        .foregroundStyle(Color.accentColor)
                }

                Spacer(minLength: 0)

                KeyboardShortcuts.Recorder(for: .audioRecording) { shortcut in
                    audioShortcut = shortcut?.description ?? ""
                }
                .fixedSize()
            }
            .padding(.vertical, 4)
        }
    }

    private var safetyCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "checkmark.shield", title: "Segmentation & Safety")

            LabeledContent("Maximum segment length", value: "59 minutes")
            LabeledContent("Crash recovery", value: "Always On")

            Toggle("Hide Screenshot Shelf while recording", isOn: $hideShelfWhileRecording)
                .onChange(of: hideShelfWhileRecording) { _ in
                    viewModel.refreshRecordingShelfVisibility()
                }
            Toggle("Show recording duration in the menu bar", isOn: $menuBarDuration)

            Divider()

            PreferencesCardHeader(systemImage: "record.circle", title: "Screen Recording")

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

            PreferencesCardCaption(
                text: "HEVC typically uses half the H.264 bitrate for a similar quality target."
            )

            Divider()

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

    private var screenAudioModeBinding: Binding<String> {
        Binding(
            get: { resolvedScreenAudioMode },
            set: { newValue in
                resolvedScreenAudioMode = newValue
                screenAudioMode = newValue
                let mode = RecordingAudioPreferenceMigration.mode(fromPreferenceValue: newValue) ?? .system
                systemAudio = mode == .system || mode == .systemAndMicrophone
            }
        )
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
            PreferencesCardHeader(systemImage: "folder", title: "Storage")

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

            PreferencesCardCaption(text: "Estimated screen recording size per minute: \(estimatedScreenSize)")
            PreferencesCardCaption(text: "Estimated audio recording size per minute: \(estimatedAudioSize)")
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

    private var estimatedScreenSize: String {
        let audioBitrate = systemAudio ? 128_000 : 0
        let estimatedBytes = Int64(averageVideoBitrate + audioBitrate) * 60 / 8
        return RecordingStorage.formattedBytes(estimatedBytes)
    }

    private var estimatedAudioSize: String {
        let mode = RecordingAudioPreferenceMigration.mode(fromPreferenceValue: audioMode) ?? .systemAndMicrophone
        let encodedBitsPerSecond: Int
        switch (mode, outputLayout == "separateTracks") {
        case (.system, _):
            encodedBitsPerSecond = 160_000
        case (.microphone, _):
            encodedBitsPerSecond = 96_000
        case (.systemAndMicrophone, true):
            encodedBitsPerSecond = 256_000
        case (.systemAndMicrophone, false):
            encodedBitsPerSecond = 160_000
        case (.none, _):
            encodedBitsPerSecond = 0
        }
        let bytesPerMinute = Int64(encodedBitsPerSecond) * 60 / 8
        return RecordingStorage.formattedBytes(bytesPerMinute)
    }

    private func preparePreferences() {
        refreshAvailableSpace()
        resolvedScreenAudioMode = RecordingAudioPreferenceMigration.preferenceValue(
            for: RecordingAudioPreferenceStore.mode(for: .screen)
        )
        audioShortcut = KeyboardShortcuts.getShortcut(for: .audioRecording)?.description ?? ""
        guard audioShortcut.isEmpty, !recordingShortcutHintShown else { return }
        recordingShortcutHintShown = true
        isShowingAudioShortcutHint = true
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
