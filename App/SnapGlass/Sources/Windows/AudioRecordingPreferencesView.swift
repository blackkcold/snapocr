import AppKit
import CaptureCore
import KeyboardShortcuts
import SharedKit
import SwiftUI

/// Settings for audio-only recordings.
///
/// Output directory, AAC bitrate, source, and layout are independent from screen
/// recordings. Shared appearance controls live on the Screen Recording page and
/// are labelled there.
struct AudioRecordingPreferencesView: View {
    @AppStorage(PreferenceKeys.recordingAudioMode)
    private var audioMode = PreferenceDefaults.recordingAudioMode
    @AppStorage(PreferenceKeys.recordingOutputLayout)
    private var outputLayout = PreferenceDefaults.recordingOutputLayout
    @AppStorage(PreferenceKeys.recordingAudioBitRate)
    private var audioBitRate = PreferenceDefaults.recordingAudioBitRate
    @AppStorage(PreferenceKeys.recordingAudioCustomOutputDirectory)
    private var customOutputDirectoryPath = ""
    @AppStorage(PreferenceKeys.recordingAudioShortcut)
    private var audioShortcut = PreferenceDefaults.recordingAudioShortcut
    @AppStorage(PreferenceKeys.recordingShortcutHintShown)
    private var shortcutHintShown = PreferenceDefaults.recordingShortcutHintShown

    @State private var destinationCapacity: RecordingDestinationCapacity?
    @State private var capacityTask: Task<Void, Never>?
    @State private var showsFirstUseHint = false

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                sourceCard
                destinationCard
                shortcutCard
            }
        }
        .onAppear(perform: preparePreferences)
        .onDisappear(perform: cancelCapacityRead)
    }

    private var sourceCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "waveform", title: "Audio")

            Picker("Audio-only recording", selection: audioModeBinding) {
                Text("System Audio").tag("system")
                Text("Microphone").tag("microphone")
                Text("System Audio + Microphone").tag("systemAndMicrophone")
            }
            .pickerStyle(.menu)
            .accessibilityHint(Text("Default for Next Recording"))

            Picker("Audio track layout", selection: outputLayoutBinding) {
                Text("Mixed Track").tag("mixed")
                Text("Separate Tracks").tag("separateTracks")
            }
            .pickerStyle(.menu)

            Picker("Audio quality", selection: audioBitRateBinding) {
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
                text: "Audio track layout applies to audio-only recordings."
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
                    .accessibilityLabel(Text("Audio recording folder"))
                    .accessibilityValue(Text(destinationDescription))

                capacityStatus
            }

            HStack {
                Button("Choose Folder…", action: chooseDirectory)
                    .buttonStyle(.borderedProminent)
                    .help("Choose a folder for new audio recordings")

                Button("Open Folder", action: openDirectory)
                    .disabled(!directoryIsAvailable)
                    .help("Open Folder")

                Button("Reset to Default", action: resetDirectory)
                    .disabled(!hasCustomDestination)
            }

            PreferencesCardCaption(
                text: "This folder is used for audio-only recordings. Existing files are not moved."
            )
            PreferencesCardCaption(
                text: "Changing the destination does not move existing recordings or create this folder."
            )
            PreferencesCardCaption(
                text: "Estimated audio recording size per minute: \(estimatedAudioSize)"
            )
        }
        .onChange(of: customOutputDirectoryPath) { _ in
            refreshCapacity()
        }
    }

    private var shortcutCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "keyboard", title: "Shortcuts")

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

            if showsFirstUseHint, audioShortcut.isEmpty {
                PreferencesCardCaption(
                    // This is one localized key; splitting it would change the lookup key.
                    // swiftlint:disable:next line_length
                    text: "No audio-recording shortcut is assigned by default. Record one here if you want a global shortcut."
                )
            }
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
                    if let startRequirement, bytes < startRequirement {
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

    private var audioModeBinding: Binding<String> {
        Binding(
            get: {
                ["system", "microphone", "systemAndMicrophone"].contains(audioMode)
                    ? audioMode
                    : PreferenceDefaults.recordingAudioMode
            },
            set: { audioMode = $0 }
        )
    }

    private var outputLayoutBinding: Binding<String> {
        Binding(
            get: {
                ["mixed", "separateTracks"].contains(outputLayout)
                    ? outputLayout
                    : PreferenceDefaults.recordingOutputLayout
            },
            set: { outputLayout = $0 }
        )
    }

    private var audioBitRateBinding: Binding<Int> {
        Binding(
            get: {
                RecordingAudioPreferenceStore.supportedBitRates.contains(audioBitRate)
                    ? audioBitRate
                    : RecordingAudioPreferenceStore.defaultBitRate
            },
            set: { audioBitRate = $0 }
        )
    }

    private var hasCustomDestination: Bool {
        RecordingDestinationPreferences.customDirectory(for: .audio) != nil
    }

    private var destinationDirectory: URL? {
        RecordingDestinationPreferences.directory(for: .audio)
    }

    private var destinationDescription: String {
        if let customDirectory = RecordingDestinationPreferences.customDirectory(for: .audio) {
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

    /// Same requirement the audio start preflight enforces, or `nil` when the
    /// persisted configuration is invalid and the budget cannot estimate.
    private var startRequirement: Int64? {
        let requirement = RecordingSpaceBudget.minimumStartRequirement(
            for: RecordingStorageConfiguration(
                audioConfiguration: RecordingAudioPreferenceStore.audioConfiguration()
            )
        )
        return requirement == .max ? nil : requirement
    }

    private func insufficientSpaceMessage(
        available: Int64,
        required: Int64
    ) -> LocalizedStringKey {
        let availableText = RecordingStorage.formattedBytes(available)
        let requiredText = RecordingStorage.formattedBytes(required)
        return "Not enough space: \(availableText) available, \(requiredText) required."
    }

    private var estimatedAudioSize: String {
        let mode = RecordingAudioPreferenceMigration.mode(
            fromPreferenceValue: audioModeBinding.wrappedValue
        ) ?? .systemAndMicrophone
        let trackCount: Int
        switch mode {
        case .none:
            trackCount = 0
        case .systemAndMicrophone:
            trackCount = outputLayoutBinding.wrappedValue == "separateTracks" ? 2 : 1
        case .system, .microphone:
            trackCount = 1
        }
        let encodedBitsPerSecond = audioBitRateBinding.wrappedValue * trackCount
        return RecordingStorage.formattedBytes(Int64(encodedBitsPerSecond) * 60 / 8)
    }

    private func preparePreferences() {
        RecordingDestinationPreferences.seedLegacySharedValuesIfNeeded()
        refreshCapacity()
        audioShortcut = KeyboardShortcuts.getShortcut(for: .audioRecording)?.description ?? ""
        guard audioShortcut.isEmpty, !shortcutHintShown else { return }
        shortcutHintShown = true
        showsFirstUseHint = true
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = AppLocalization.string("Choose a folder for new audio recordings")
        panel.prompt = AppLocalization.string("Choose Folder")

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        RecordingDestinationPreferences.setCustomDirectory(selectedURL, for: .audio)
        customOutputDirectoryPath = selectedURL.standardizedFileURL.path
        refreshCapacity()
    }

    private func openDirectory() {
        guard let destinationDirectory else { return }
        NSWorkspace.shared.open(destinationDirectory)
    }

    private func resetDirectory() {
        RecordingDestinationPreferences.reset(for: .audio)
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
            ? RecordingDestinationPreferences.customDirectoryVolumeUUID(for: .audio)
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
