import SwiftUI
import KeyboardShortcuts
import SharedKit
import HistoryCore
import ServiceManagement

struct PreferencesView: View {
    @State private var selection: PreferencesSection = .general

    var body: some View {
        HStack(spacing: 0) {
            List(PreferencesSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
                    .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Label(selection.title, systemImage: selection.systemImage)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                Divider()

                Group {
                    switch selection {
                    case .general: GeneralPreferencesView()
                    case .capture: CapturePreferencesView()
                    case .ocr: OCRPreferencesView()
                    case .shortcuts: ShortcutsPreferencesView()
                    case .history: HistoryPreferencesView()
                    case .developer: DeveloperPreferencesView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum PreferencesSection: String, CaseIterable, Identifiable {
    case general, capture, ocr, shortcuts, history, developer

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .ocr: "OCR"
        case .shortcuts: "Shortcuts"
        case .history: "History"
        case .developer: "Developer"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .ocr: "text.viewfinder"
        case .shortcuts: "keyboard"
        case .history: "clock.arrow.circlepath"
        case .developer: "hammer"
        }
    }
}

struct GeneralPreferencesView: View {
    @AppStorage(PreferenceKeys.launchAtLogin)
    private var launchAtLogin = PreferenceDefaults.launchAtLogin
    @State private var launchError: String?
    @AppStorage(PreferenceKeys.appLanguage)
    private var appLanguage = PreferenceDefaults.appLanguage
    
    var body: some View {
        Form {
            Section("Language") {
                Picker("App language", selection: $appLanguage) {
                    Text("System Default").tag(AppLanguage.system.rawValue)
                    Text("English").tag(AppLanguage.english.rawValue)
                    Text("Simplified Chinese").tag(AppLanguage.simplifiedChinese.rawValue)
                }
                .pickerStyle(.menu)

                Text("Language changes apply immediately to open SnapGlass windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: launchAtLoginBinding)

                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .task {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                launchAtLogin = enabled
                launchError = nil
                Task { await updateLaunchAtLogin(enabled: enabled) }
            }
        )
    }

    private func updateLaunchAtLogin(enabled: Bool) async {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = error.localizedDescription
        }
    }
}

struct CapturePreferencesView: View {
    @AppStorage(PreferenceKeys.captureOpenEditor)
    private var openEditor = PreferenceDefaults.captureOpenEditor
    @AppStorage(PreferenceKeys.captureCopyToClipboard)
    private var copyToClipboard = PreferenceDefaults.captureCopyToClipboard
    @AppStorage(PreferenceKeys.captureIncludeCursor)
    private var includeCursor = PreferenceDefaults.captureIncludeCursor
    @AppStorage(PreferenceKeys.captureAutoOCR)
    private var autoOCR = PreferenceDefaults.captureAutoOCR
    @AppStorage(PreferenceKeys.captureCopyOCRText)
    private var copyOCRText = PreferenceDefaults.captureCopyOCRText
    @AppStorage(PreferenceKeys.captureSelectionStyle)
    private var selectionStyle = PreferenceDefaults.captureSelectionStyle
    @AppStorage(PreferenceKeys.captureHighResolution)
    private var highResolution = PreferenceDefaults.captureHighResolution
    @AppStorage(PreferenceKeys.captureImageFormat)
    private var imageFormat = PreferenceDefaults.captureImageFormat
    @AppStorage(PreferenceKeys.captureJPEGQuality)
    private var jpegQuality = PreferenceDefaults.captureJPEGQuality
    
    var body: some View {
        Form {
            Section("After Capture") {
                Toggle("Open annotation editor", isOn: $openEditor)
                Toggle("Copy image to clipboard", isOn: $copyToClipboard)
                Toggle("Run OCR automatically", isOn: $autoOCR)

                Toggle("Replace clipboard with recognized text", isOn: $copyOCRText)
                    .disabled(!autoOCR)
                    .help("When disabled, the captured image remains on the clipboard.")
            }

            Section("Image") {
                Toggle("Include pointer", isOn: $includeCursor)
                Toggle("Native Retina resolution", isOn: $highResolution)

                Picker("Selection style", selection: $selectionStyle) {
                    Text("Rectangle").tag(CaptureSelectionStyle.rectangle.rawValue)
                    Text("Freeform").tag(CaptureSelectionStyle.freeform.rawValue)
                }
                .pickerStyle(.segmented)

                Picker("Saved image format", selection: $imageFormat) {
                    Text("PNG (lossless)").tag(ImageFileFormat.png.rawValue)
                    Text("JPEG (smaller)").tag(ImageFileFormat.jpeg.rawValue)
                }
                .pickerStyle(.menu)

                if imageFormat == ImageFileFormat.jpeg.rawValue {
                    VStack(alignment: .leading) {
                        LabeledContent("JPEG quality") {
                            Text(jpegQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                        Slider(value: $jpegQuality, in: 0.5...1, step: 0.05)
                    }
                }

                Text("Freeform captures always use PNG to preserve transparency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

struct OCRPreferencesView: View {
    @AppStorage(PreferenceKeys.ocrLanguagePriority)
    private var languagePriority = PreferenceDefaults.ocrLanguagePriority
    @AppStorage(PreferenceKeys.ocrConfidenceThreshold)
    private var confidenceThreshold = PreferenceDefaults.ocrConfidenceThreshold
    @AppStorage(PreferenceKeys.ocrEngine)
    private var engine = PreferenceDefaults.ocrEngine
    
    var body: some View {
        Form {
            Section("Recognition") {
                Picker("Language Priority:", selection: $languagePriority) {
                    Text("Automatic").tag("auto")
                    Text("English First").tag("en")
                    Text("Chinese First").tag("zh")
                }
                .pickerStyle(.menu)

                Picker("OCR Engine:", selection: $engine) {
                    Text("Apple Vision").tag("vision")
                    Text("Tesseract (Vision fallback)").tag("tesseract")
                }
                .pickerStyle(.menu)
            }

            Section("Quality") {
                VStack(alignment: .leading) {
                    LabeledContent("Confidence threshold") {
                        Text(confidenceThreshold, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    Slider(value: $confidenceThreshold, in: 0...1, step: 0.05)
                }
            }
        }
        .padding()
    }
}

struct ShortcutsPreferencesView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Area Capture:", name: .captureArea)
            KeyboardShortcuts.Recorder("Window Capture:", name: .captureWindow)
            KeyboardShortcuts.Recorder("Fullscreen Capture:", name: .captureFullscreen)
            KeyboardShortcuts.Recorder("OCR from Clipboard:", name: .ocrFromClipboard)
        }
        .padding()
    }
}

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

    @State private var retentionDaysInput = String(PreferenceDefaults.historyRetentionDays)
    @State private var maxItemsInput = String(PreferenceDefaults.historyMaxItems)
    @State private var keepIndefinitely = false
    @State private var lastFiniteRetentionDays = PreferenceDefaults.historyRetentionDays
    @State private var storageSize = PreferenceDefaults.historyStorageSize
    @State private var confirmsPolicyChange = false
    @State private var policyError: String?
    
    var body: some View {
        Form {
            Section("Screenshot Retention") {
                LabeledContent("Maximum screenshots") {
                    TextField("200", text: $maxItemsInput)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .onSubmit(normalizeMaxItemsInput)
                }

                if let maxItemsValidationMessage {
                    Text(maxItemsValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Toggle("Keep indefinitely", isOn: $keepIndefinitely)
                    .onChange(of: keepIndefinitely) { forever in
                        if forever {
                            if let value = validRetentionDays {
                                lastFiniteRetentionDays = value
                            }
                        } else {
                            retentionDaysInput = String(max(lastFiniteRetentionDays, 1))
                        }
                    }

                if !keepIndefinitely {
                    LabeledContent("Retention period") {
                        HStack(spacing: 6) {
                            TextField("30", text: $retentionDaysInput)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                .onSubmit(normalizeRetentionDaysInput)
                            Text("days")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let retentionValidationMessage {
                        Text(retentionValidationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Text("Favourite screenshots are not removed by count or age limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Apply Retention Policy") {
                    normalizeInputs()
                    confirmsPolicyChange = true
                }
                .disabled(!hasPolicyChanges || !inputsAreValid)
            }

            Section("Storage") {
                VStack(alignment: .leading) {
                    LabeledContent("Maximum storage") {
                        HStack(spacing: 4) {
                            Text(storageSize, format: .number.precision(.fractionLength(1)))
                                .monospacedDigit()
                            Text("GB")
                        }
                    }
                    Slider(value: $storageSize, in: 0.1...10.0, step: 0.1)
                }
            }

            Toggle("Auto-save captures to history", isOn: $autoSave)
                .padding(.top, 8)
                .help("Automatically save screenshots and thumbnails to local encrypted history")

            if autoSave {
                Toggle("Save full OCR text", isOn: $saveFullText)
                    .help("Store complete OCR text in encrypted history entries. Off stores an empty text field.")
            }
        }
        .padding()
        .onAppear {
            keepIndefinitely = storedRetentionDays == 0
            lastFiniteRetentionDays = storedRetentionDays == 0
                ? PreferenceDefaults.historyRetentionDays
                : storedRetentionDays
            retentionDaysInput = String(lastFiniteRetentionDays)
            maxItemsInput = String(storedMaxItems)
            storageSize = storedStorageSize
        }
        .alert("Apply History Limits?", isPresented: $confirmsPolicyChange) {
            Button("Cancel", role: .cancel) {}
            Button("Apply", role: .destructive) {
                applyPolicy()
            }
        } message: {
            Text("Older non-favourite screenshots exceeding the new count or age limits may be permanently removed.")
        }
        .alert("History Policy Error", isPresented: Binding(
            get: { policyError != nil },
            set: { if !$0 { policyError = nil } }
        )) {
            Button("OK") { policyError = nil }
        } message: {
            Text(policyError ?? "Unknown error")
        }
    }

    private var hasPolicyChanges: Bool {
        effectiveRetentionDays != storedRetentionDays
            || validMaxItems != storedMaxItems
            || storageSize != storedStorageSize
    }

    private var inputsAreValid: Bool {
        validMaxItems != nil && (keepIndefinitely || validRetentionDays != nil)
    }

    private var validMaxItems: Int? {
        guard let value = Int(maxItemsInput.trimmingCharacters(in: .whitespaces)),
              (10...5_000).contains(value) else { return nil }
        return value
    }

    private var validRetentionDays: Int? {
        guard let value = Int(retentionDaysInput.trimmingCharacters(in: .whitespaces)),
              (1...3_650).contains(value) else { return nil }
        return value
    }

    private var effectiveRetentionDays: Int? {
        keepIndefinitely ? 0 : validRetentionDays
    }

    private var maxItemsValidationMessage: LocalizedStringKey? {
        validMaxItems == nil ? "Enter a whole number from 10 to 5,000." : nil
    }

    private var retentionValidationMessage: LocalizedStringKey? {
        validRetentionDays == nil ? "Enter a whole number from 1 to 3,650 days." : nil
    }

    private func normalizeInputs() {
        normalizeMaxItemsInput()
        if !keepIndefinitely { normalizeRetentionDaysInput() }
    }

    private func normalizeMaxItemsInput() {
        let parsed = Int(maxItemsInput.trimmingCharacters(in: .whitespaces)) ?? storedMaxItems
        maxItemsInput = String(min(max(parsed, 10), 5_000))
    }

    private func normalizeRetentionDaysInput() {
        let parsed = Int(retentionDaysInput.trimmingCharacters(in: .whitespaces)) ?? lastFiniteRetentionDays
        let normalized = min(max(parsed, 1), 3_650)
        lastFiniteRetentionDays = normalized
        retentionDaysInput = String(normalized)
    }

    private func applyPolicy() {
        guard let retentionDays = effectiveRetentionDays,
              let maxItems = validMaxItems else { return }
        storedRetentionDays = retentionDays
        storedMaxItems = maxItems
        storedStorageSize = storageSize
        Task {
            do {
                try await HistoryActor.shared?.reloadConfiguredPolicyAndCleanup()
            } catch {
                policyError = error.localizedDescription
            }
        }
    }
}

struct DeveloperPreferencesView: View {
    @AppStorage(PreferenceKeys.developerMode)
    private var devMode = PreferenceDefaults.developerMode
    @AppStorage(PreferenceKeys.engineComparison)
    private var engineComparison = PreferenceDefaults.engineComparison
    @AppStorage(PreferenceKeys.forceUpdateAvailable)
    private var forceUpdateAvailable = PreferenceDefaults.forceUpdateAvailable
    
    var body: some View {
        Form {
            Toggle("Enable Developer Mode", isOn: $devMode)
            
            if devMode {
                Toggle("Enable Engine Comparison", isOn: $engineComparison)
                Toggle("Force Latest Release as Update", isOn: $forceUpdateAvailable)

                Text("When enabled, Check for Updates shows the latest GitHub Release even if its version is not newer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
