import AppKit
import CaptureCore
import SharedKit
import SwiftUI

/// Settings for screen recordings.
///
/// Video quality, screen audio, and the screen destination live here. Audio-only
/// source, layout, bitrate, and destination live on the Audio Recording page.
struct RecordingPreferencesView: View {
    @EnvironmentObject private var viewModel: CaptureViewModel
    @AppStorage(PreferenceKeys.recordingScreenAudioMode)
    private var screenAudioMode = PreferenceDefaults.recordingScreenAudioMode
    @AppStorage(PreferenceKeys.recordingScreenAudioBitRate)
    private var screenAudioBitRate = PreferenceDefaults.recordingScreenAudioBitRate
    @AppStorage(PreferenceKeys.recordingSystemAudio)
    private var systemAudio = PreferenceDefaults.recordingSystemAudio
    @AppStorage(PreferenceKeys.recordingScreenCustomOutputDirectory)
    private var customOutputDirectoryPath = ""
    @AppStorage(PreferenceKeys.recordingHideShelfWhileRecording)
    private var hideShelfWhileRecording = PreferenceDefaults.recordingHideShelfWhileRecording

    @AppStorage(PreferenceKeys.recordingVideoCodec)
    private var videoCodec = PreferenceDefaults.recordingVideoCodec
    @AppStorage(PreferenceKeys.recordingResolution)
    private var resolution = PreferenceDefaults.recordingResolution
    @AppStorage(PreferenceKeys.recordingFrameRate)
    private var frameRate = PreferenceDefaults.recordingFrameRate
    @AppStorage(PreferenceKeys.recordingAverageVideoBitrate)
    private var averageVideoBitrate = PreferenceDefaults.recordingAverageVideoBitrate
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

    @State private var resolvedScreenAudioMode = PreferenceDefaults.recordingScreenAudioMode
    @State private var destinationCapacity: RecordingDestinationCapacity?
    @State private var capacityTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                screenCard
                destinationCard
                safetyCard
                controlPanelCard
            }
        }
        .onAppear(perform: preparePreferences)
        .onDisappear(perform: cancelCapacityRead)
    }

    private var screenCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "record.circle", title: "Screen Recording")

            Picker("Screen recording audio", selection: screenAudioModeBinding) {
                Text("System Audio").tag("system")
                Text("Microphone").tag("microphone")
                Text("System Audio + Microphone").tag("systemAndMicrophone")
                Text("No Audio").tag("none")
            }
            .pickerStyle(.menu)
            .accessibilityHint(Text("Default for Next Recording"))

            Picker("Screen audio quality", selection: screenBitRateBinding) {
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
                text: "Screen recording source tracks are embedded separately in the video."
            )

            Divider()

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
            PreferencesCardCaption(text: "Default for Next Recording")
        }
    }

    private var destinationCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "folder", title: "Storage")

            VStack(alignment: .leading, spacing: 6) {
                Text(destinationDescription)
                    .font(.callout)
                    .foregroundStyle(destinationUnavailable ? .red : .secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel(Text("Screen recording folder"))
                    .accessibilityValue(Text(destinationDescription))

                capacityStatus
            }

            HStack {
                Button("Choose Folder…", action: chooseDirectory)
                    .buttonStyle(.borderedProminent)
                    .help("Choose a folder for new screen recordings")

                Button("Open Folder", action: openDirectory)
                    .disabled(!directoryIsAvailable)
                    .help("Open Folder")

                Button("Reset to Default", action: resetDirectory)
                    .disabled(!hasCustomDestination)
            }

            PreferencesCardCaption(
                text: "This folder is used for screen recordings. Existing files are not moved."
            )
            PreferencesCardCaption(
                text: "Changing the destination does not move existing recordings or create this folder."
            )
            PreferencesCardCaption(
                text: "Estimated screen recording size per minute: \(estimatedScreenSize)"
            )
        }
        .onChange(of: customOutputDirectoryPath) { _ in
            refreshCapacity()
        }
    }

    private var safetyCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "checkmark.shield", title: "Segmentation & Safety")

            LabeledContent("Maximum segment length", value: "59 minutes")
            LabeledContent {
                Text("Checks for unfinished recordings at launch")
            } label: {
                Text("Crash recovery")
            }

            Toggle("Hide Screenshot Shelf while recording", isOn: $hideShelfWhileRecording)
                .onChange(of: hideShelfWhileRecording) { _ in
                    viewModel.refreshRecordingShelfVisibility()
                }

            PreferencesCardCaption(
                text: "Shelf visibility applies to every recording."
            )
        }
    }

    private var controlPanelCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "rectangle.inset.filled", title: "Control panel")

            HStack(spacing: 10) {
                Text("Panel opacity")
                Slider(value: hudOpacityBinding, in: RecordingHUDPreferences.opacityRange, step: 0.05)
                    .accessibilityLabel(Text("Panel opacity"))
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
                text: "Panel appearance is shared by audio and screen recordings."
            )
            PreferencesCardCaption(
                text: "Panel opacity and hover restore are unavailable while the panel is hidden."
            )
            PreferencesCardCaption(
                text: "The panel never covers the captured area; drag it to another corner at any time."
            )
        }
    }

    @ViewBuilder
    private var capacityStatus: some View {
        if let capacity = destinationCapacity {
            switch capacity {
            case let .available(bytes, probedDirectory, _):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Available space: \(RecordingStorage.formattedBytes(bytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            Text("Available space: \(RecordingStorage.formattedBytes(bytes))")
                        )
                    if probedDirectory.standardizedFileURL != destinationDirectory?.standardizedFileURL {
                        Text("The default folder will be created when recording starts.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if bytes < startRequirement {
                        Text(insufficientSpaceMessage(available: bytes, required: startRequirement))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel(
                                Text(insufficientSpaceMessage(available: bytes, required: startRequirement))
                            )
                    }
                }
            case .locationUnavailable:
                Group {
                    if hasCustomDestination {
                        Text("The selected recording folder is unavailable. Choose it again in Preferences.")
                    } else {
                        Text("The default recording folder is unavailable.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.red)
            case .capacityUnreadable:
                Text("Could not check free space in the recording folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if !hasCustomDestination {
            Text("The default folder will be created when recording starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var screenBitRateBinding: Binding<Int> {
        Binding(
            get: {
                RecordingAudioPreferenceStore.supportedBitRates.contains(screenAudioBitRate)
                    ? screenAudioBitRate
                    : RecordingAudioPreferenceStore.defaultBitRate
            },
            set: { screenAudioBitRate = $0 }
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
        RecordingDestinationPreferences.customDirectory(for: .screen) != nil
    }

    private var destinationDirectory: URL? {
        RecordingDestinationPreferences.directory(for: .screen)
    }

    private var destinationDescription: String {
        if let customDirectory = RecordingDestinationPreferences.customDirectory(for: .screen) {
            return customDirectory.path
        }
        return "Movies/SnapGlass/Recordings"
    }

    private var directoryIsAvailable: Bool {
        guard let destinationDirectory,
              let capacity = destinationCapacity else { return false }
        guard case let .available(_, probedDirectory, _) = capacity else { return false }
        return probedDirectory.standardizedFileURL == destinationDirectory.standardizedFileURL
    }

    private var destinationUnavailable: Bool {
        guard let capacity = destinationCapacity else { return false }
        if case .locationUnavailable = capacity { return true }
        return false
    }

    private var startRequirement: Int64 {
        RecordingStorage.minimumStartFreeSpace
    }

    private func insufficientSpaceMessage(
        available: Int64,
        required: Int64
    ) -> LocalizedStringKey {
        let availableText = RecordingStorage.formattedBytes(available)
        let requiredText = RecordingStorage.formattedBytes(required)
        return "Not enough space: \(availableText) available, \(requiredText) required."
    }

    private var estimatedScreenSize: String {
        let mode = RecordingAudioPreferenceMigration.mode(
            fromPreferenceValue: screenAudioModeBinding.wrappedValue
        ) ?? .system
        let audioTrackCount: Int
        switch mode {
        case .none:
            audioTrackCount = 0
        case .system, .microphone:
            audioTrackCount = 1
        case .systemAndMicrophone:
            audioTrackCount = 2
        }
        let encodedBitsPerSecond = averageVideoBitrate
            + (screenBitRateBinding.wrappedValue * audioTrackCount)
        return RecordingStorage.formattedBytes(Int64(encodedBitsPerSecond) * 60 / 8)
    }

    private func preparePreferences() {
        RecordingDestinationPreferences.seedLegacySharedValuesIfNeeded()
        refreshCapacity()
        resolvedScreenAudioMode = RecordingAudioPreferenceMigration.preferenceValue(
            for: RecordingAudioPreferenceStore.mode(for: .screen)
        )
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
        RecordingDestinationPreferences.setCustomDirectory(selectedURL, for: .screen)
        customOutputDirectoryPath = selectedURL.standardizedFileURL.path
        refreshCapacity()
    }

    private func openDirectory() {
        guard let destinationDirectory else { return }
        NSWorkspace.shared.open(destinationDirectory)
    }

    private func resetDirectory() {
        RecordingDestinationPreferences.reset(for: .screen)
        customOutputDirectoryPath = ""
        refreshCapacity()
    }

    private func refreshCapacity() {
        capacityTask?.cancel()
        destinationCapacity = nil
        guard let destinationDirectory else {
            destinationCapacity = .locationUnavailable
            return
        }
        let isCustom = hasCustomDestination
        let expectedVolumeUUID = isCustom
            ? RecordingDestinationPreferences.customDirectoryVolumeUUID(for: .screen)
            : nil
        capacityTask = Task { @MainActor in
            let capacity = await RecordingDestinationProbe.inspect(
                directory: destinationDirectory,
                isCustom: isCustom,
                expectedVolumeUUID: expectedVolumeUUID
            )
            guard !Task.isCancelled else { return }
            destinationCapacity = capacity
        }
    }

    private func cancelCapacityRead() {
        capacityTask?.cancel()
        capacityTask = nil
    }
}
