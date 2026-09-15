import AppKit
import HistoryCore
import SharedKit
import SwiftUI

// MARK: - History Preferences

struct HistoryPreferencesView: View {
    @AppStorage(PreferenceKeys.historyRetentionDays)
    private var storedRetentionDays = PreferenceDefaults.historyRetentionDays
    @AppStorage(PreferenceKeys.historyMaxItems)
    private var storedMaxItems = PreferenceDefaults.historyMaxItems
    @AppStorage(PreferenceKeys.historyStorageSize)
    private var storedStorageSize = PreferenceDefaults.historyStorageSize
    @AppStorage(PreferenceKeys.historyAutoSave)
    private var autoSave = PreferenceDefaults.historyAutoSave
    @AppStorage(PreferenceKeys.historySaveFullText)
    private var saveFullText = PreferenceDefaults.historySaveFullText
    @AppStorage(PreferenceKeys.colorHistoryEnabled)
    private var colorHistoryEnabled = PreferenceDefaults.colorHistoryEnabled
    @AppStorage(PreferenceKeys.colorHistoryMaxItems)
    private var storedColorHistoryMaxItems = PreferenceDefaults.colorHistoryMaxItems

    @State private var maxItems = PreferenceDefaults.historyMaxItems
    @State private var retentionDays = PreferenceDefaults.historyRetentionDays
    @State private var keepIndefinitely = false
    @State private var lastFiniteRetentionDays = PreferenceDefaults.historyRetentionDays
    @State private var storageSize = PreferenceDefaults.historyStorageSize
    @State private var colorHistoryMaxItems = PreferenceDefaults.colorHistoryMaxItems
    @State private var isClearingColors = false

    private let logger = Logger(category: "preferences")

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                dashboardCard

                retentionCard

                storageCard

                colorHistoryCard

                saveCard
            }
        }
        .onAppear {
            keepIndefinitely = storedRetentionDays == 0
            lastFiniteRetentionDays = storedRetentionDays == 0
                ? PreferenceDefaults.historyRetentionDays
                : storedRetentionDays
            retentionDays = lastFiniteRetentionDays
            maxItems = storedMaxItems
            storageSize = storedStorageSize
            colorHistoryMaxItems = storedColorHistoryMaxItems
        }
    }

    private var dashboardCard: some View {
        HistoryStorageDashboard(storageSizeGB: storageSize)
    }

    private var retentionCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "calendar", title: "Screenshot Retention") {
                Toggle("Keep indefinitely", isOn: $keepIndefinitely)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: keepIndefinitely) { forever in
                        if forever {
                            lastFiniteRetentionDays = retentionDays
                            storedRetentionDays = 0
                            applyPolicy()
                        } else {
                            retentionDays = max(lastFiniteRetentionDays, 1)
                        }
                    }
            }

            TriValueControl(
                title: "Maximum screenshots",
                unit: "items",
                presets: [50, 100, 200, 500, 1000],
                range: 10...5_000,
                value: maxItems
            ) { newValue in
                maxItems = newValue
                storedMaxItems = newValue
                applyPolicy()
            }

            if !keepIndefinitely {
                TriValueControl(
                    title: "Retention period",
                    unit: "days",
                    presets: [7, 30, 90, 365],
                    range: 1...3_650,
                    value: retentionDays
                ) { newValue in
                    retentionDays = newValue
                    storedRetentionDays = newValue
                    applyPolicy()
                }
            }

            PreferencesCardCaption(text: "Favourite screenshots are not removed by count or age limits.")
        }
    }

    private var storageCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "internaldrive", title: "Maximum storage")

            LabeledContent {
                HStack(spacing: 2) {
                    Text(storageSize, format: .number.precision(.fractionLength(1)))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    Text(" GB")
                        .foregroundColor(.secondary)
                }
            } label: {
                Text("Capacity")
            }

            Slider(value: $storageSize, in: 0.1...10.0, step: 0.1)
                .onChange(of: storageSize) { newValue in
                    storedStorageSize = newValue
                    applyPolicy()
                }
        }
    }

    private var saveCard: some View {
        PreferencesCard {
            Toggle("Auto-save captures to history", isOn: $autoSave)
                .help("Automatically save screenshots and thumbnails to local encrypted history")

            if autoSave {
                Toggle("Save full OCR text", isOn: $saveFullText)
                    .help("Store complete OCR text in encrypted history entries. Off stores an empty text field.")
            }
        }
    }

    private var colorHistoryCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "eyedropper", title: "Color History")

            Toggle("Record picked colors", isOn: $colorHistoryEnabled)
                .help("Record colors copied with the area or editor color picker")

            if colorHistoryEnabled {
                TriValueControl(
                    title: "Maximum color entries",
                    unit: "items",
                    presets: [50, 100, 200, 500],
                    range: 10...5_000,
                    value: colorHistoryMaxItems
                ) { newValue in
                    colorHistoryMaxItems = newValue
                    storedColorHistoryMaxItems = newValue
                }
            }

            Button(role: .destructive) {
                isClearingColors = true
            } label: {
                Label("Clear Colors", systemImage: "trash")
            }

            PreferencesCardCaption(
                text: "Colors are stored encrypted on this Mac only. Copying a color with the picker records it here."
            )
        }
        .alert("Clear Color History?", isPresented: $isClearingColors) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await clearColorHistory() }
            }
        } message: {
            Text("This will permanently delete all color entries.")
        }
    }

    private func clearColorHistory() async {
        guard let colorHistory = ColorHistoryStore.shared else { return }
        do {
            try await colorHistory.clear()
        } catch {
            logger.error("Failed to clear color history: \(error.localizedDescription)")
        }
    }

    private func applyPolicy() {
        Task {
            do {
                try await HistoryActor.shared?.reloadConfiguredPolicyAndCleanup()
            } catch {
                logger.error("Failed to apply history retention policy: \(error.localizedDescription)")
            }
        }
    }
}
