import SwiftUI
import KeyboardShortcuts
import SharedKit
import HistoryCore
import ServiceManagement

struct PreferencesView: View {
    @State private var selection: PreferencesSection = .general
    @State private var isSidebarCollapsed = false
    @State private var windowWidth = PreferencesSpacing.idealWindowWidth

    var body: some View {
        GlassGroup {
            HStack(alignment: .top, spacing: 12) {
                sidebar

                content
            }
            .frame(
                minWidth: PreferencesSpacing.minWindowWidth,
                idealWidth: PreferencesSpacing.idealWindowWidth,
                maxWidth: .infinity,
                minHeight: PreferencesSpacing.minWindowHeight,
                idealHeight: PreferencesSpacing.idealWindowHeight,
                maxHeight: .infinity
            )
            .padding(12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .topLeading) { windowTint }
            .background { windowSizeReader }
        }
        .containerShape(
            RoundedRectangle(
                cornerRadius: PreferencesSpacing.resolvedWindowCornerRadius(forWidth: windowWidth)
            )
        )
    }

    private var windowSizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width) { newWidth in
                    let snapped = newWidth.rounded()
                    if abs(snapped - windowWidth) > 4 {
                        windowWidth = snapped
                    }
                }
        }
        .allowsHitTesting(false)
    }

    private var windowTint: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.08), .clear],
            startPoint: .topLeading,
            endPoint: .center
        )
        .allowsHitTesting(false)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            PreferencesSidebarHeader(collapsed: isSidebarCollapsed) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSidebarCollapsed.toggle()
                }
            }

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(PreferencesSection.allCases) { section in
                        PreferencesSidebarRow(
                            section: section,
                            isSelected: section == selection,
                            collapsed: isSidebarCollapsed
                        ) {
                            selection = section
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: isSidebarCollapsed ? 56 : 212)
        .frame(maxHeight: .infinity)
        .glassSurface(in: .concentric(minimumRadius: 16), fallbackMaterial: .thinMaterial)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreferencesPageHeader(section: selection)

            Divider()

            Group {
                switch selection {
                case .general: GeneralPreferencesView()
                case .appearance: AppearancePreferencesView()
                case .capture: CapturePreferencesView()
                case .ocr: OCRPreferencesView()
                case .shortcuts: ShortcutsPreferencesView()
                case .history: HistoryPreferencesView()
                case .developer: DeveloperPreferencesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreferencesSidebarRow: View {
    let section: PreferencesSection
    let isSelected: Bool
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                if !collapsed {
                    Text(section.title)
                        .lineLimit(1)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                    Spacer(minLength: 0)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .padding(.horizontal, collapsed ? 0 : 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .glassInteractive(
                in: .rounded(8),
                tinted: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(section.title))
    }
}

struct GeneralPreferencesView: View {
    @AppStorage(PreferenceKeys.launchAtLogin)
    private var launchAtLogin = PreferenceDefaults.launchAtLogin
    @State private var launchError: String?
    @AppStorage(PreferenceKeys.appLanguage)
    private var appLanguage = PreferenceDefaults.appLanguage
    
    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                languageCard

                startupCard
            }
        }
        .task {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var languageCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "globe", title: "Language")

            Picker("App language", selection: $appLanguage) {
                Text("System Default").tag(AppLanguage.system.rawValue)
                Text("English").tag(AppLanguage.english.rawValue)
                Text("Simplified Chinese").tag(AppLanguage.simplifiedChinese.rawValue)
                Text("Japanese").tag(AppLanguage.japanese.rawValue)
                Text("Korean").tag(AppLanguage.korean.rawValue)
            }
            .pickerStyle(.menu)

            PreferencesCardCaption(text: "Language changes apply immediately to open SnapGlass windows.")
        }
    }

    private var startupCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "play.circle", title: "Startup")

            Toggle("Launch at login", isOn: launchAtLoginBinding)

            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
        ScrollView {
            PreferencesCardGrid {
                afterCaptureCard

                imageCard
            }
        }
    }

    private var afterCaptureCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "camera.viewfinder", title: "After Capture")

            PreferencesCardCaption(
                text: """
                Area captures ask whether to copy or edit when you confirm the selection. \
                These settings apply to window, fullscreen, and scrolling captures.
                """
            )

            Toggle("Open annotation editor", isOn: $openEditor)
            Toggle("Copy image to clipboard", isOn: $copyToClipboard)
            Toggle("Run OCR automatically", isOn: $autoOCR)

            Toggle("Replace clipboard with recognized text", isOn: $copyOCRText)
                .disabled(!autoOCR)
                .help("When enabled, recognized text is copied automatically after capture.")
        }
    }

    private var imageCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "photo", title: "Image")

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

            PreferencesCardCaption(text: "Freeform captures always use PNG to preserve transparency.")
        }
    }
}

struct OCRPreferencesView: View {
    @AppStorage(PreferenceKeys.ocrLanguagePriority)
    private var languagePriority = PreferenceDefaults.ocrLanguagePriority
    @State private var enabledLanguages = PreferenceDefaults.ocrEnabledLanguages
    @AppStorage(PreferenceKeys.ocrConfidenceThreshold)
    private var confidenceThreshold = PreferenceDefaults.ocrConfidenceThreshold
    @AppStorage(PreferenceKeys.ocrEngine)
    private var engine = PreferenceDefaults.ocrEngine

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                recognitionCard

                qualityCard
            }
        }
        .onAppear {
            enabledLanguages = UserDefaults.standard.stringArray(
                forKey: PreferenceKeys.ocrEnabledLanguages
            ) ?? PreferenceDefaults.ocrEnabledLanguages
        }
    }

    private var recognitionCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "text.viewfinder", title: "Recognition")

            Picker("Language Priority:", selection: $languagePriority) {
                Text("Automatic").tag("auto")
                Text("English First").tag("en")
                Text("Chinese First").tag("zh")
                Text("Japanese First").tag("ja")
                Text("Korean First").tag("ko")
            }
            .pickerStyle(.menu)

            Divider()

            VStack(alignment: .leading, spacing: PreferencesSpacing.rowGap) {
                Text("Enabled Languages")
                    .font(.headline)

                ForEach(OCRLanguageOption.allCases) { option in
                    Toggle(option.displayName, isOn: enabledBinding(for: option.code))
                }

                PreferencesCardCaption(
                    text: "Disable languages you rarely use to prevent visually similar characters (such as Japanese kanji and Chinese hanzi) from being misrecognized."
                )
            }

            Picker("OCR Engine:", selection: $engine) {
                Text("Apple Vision").tag("vision")
                Text("Tesseract (Vision fallback)").tag("tesseract")
            }
            .pickerStyle(.menu)
        }
    }

    private func enabledBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { enabledLanguages.contains(code) },
            set: { isOn in
                if isOn {
                    if !enabledLanguages.contains(code) {
                        enabledLanguages.append(code)
                    }
                } else {
                    enabledLanguages.removeAll { $0 == code }
                }
                UserDefaults.standard.set(enabledLanguages, forKey: PreferenceKeys.ocrEnabledLanguages)
            }
        )
    }

    private var qualityCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "gauge.with.dots.needle.67percent", title: "Quality")

            VStack(alignment: .leading) {
                LabeledContent("Confidence threshold") {
                    Text(confidenceThreshold, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Slider(value: $confidenceThreshold, in: 0...1, step: 0.05)
            }
        }
    }
}

struct ShortcutsPreferencesView: View {
    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                PreferencesCard {
                    PreferencesCardHeader(systemImage: "keyboard", title: "Global Shortcuts") {
                        Button("Reset All") {
                            KeyboardShortcuts.reset(.captureArea)
                            KeyboardShortcuts.reset(.captureWindow)
                            KeyboardShortcuts.reset(.captureFullscreen)
                            KeyboardShortcuts.reset(.ocrFromClipboard)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    VStack(spacing: 0) {
                        shortcutRow(
                            title: "Area Capture",
                            systemImage: "viewfinder",
                            name: .captureArea
                        )
                        Divider()

                        shortcutRow(
                            title: "Window Capture",
                            systemImage: "macwindow",
                            name: .captureWindow
                        )
                        Divider()

                        shortcutRow(
                            title: "Fullscreen Capture",
                            systemImage: "rectangle.inset.filled",
                            name: .captureFullscreen
                        )
                        Divider()

                        shortcutRow(
                            title: "OCR from Clipboard",
                            systemImage: "text.viewfinder",
                            name: .ocrFromClipboard
                        )
                    }
                }
            }
        }
    }

    private func shortcutRow(
        title: String,
        systemImage: String,
        name: KeyboardShortcuts.Name
    ) -> some View {
        HStack(spacing: 12) {
            Label {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
            }
            .frame(width: 200, alignment: .leading)

            Spacer(minLength: 0)

            KeyboardShortcuts.Recorder(for: name)
                .fixedSize()
        }
        .padding(.vertical, 6)
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

    @State private var maxItems = PreferenceDefaults.historyMaxItems
    @State private var retentionDays = PreferenceDefaults.historyRetentionDays
    @State private var keepIndefinitely = false
    @State private var lastFiniteRetentionDays = PreferenceDefaults.historyRetentionDays
    @State private var storageSize = PreferenceDefaults.historyStorageSize

    private let logger = Logger(category: "preferences")

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                dashboardCard

                retentionCard

                storageCard

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

struct DeveloperPreferencesView: View {
    @AppStorage(PreferenceKeys.developerMode)
    private var devMode = PreferenceDefaults.developerMode
    @AppStorage(PreferenceKeys.engineComparison)
    private var engineComparison = PreferenceDefaults.engineComparison
    @AppStorage(PreferenceKeys.forceUpdateAvailable)
    private var forceUpdateAvailable = PreferenceDefaults.forceUpdateAvailable
    
    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                PreferencesCard {
                    PreferencesCardHeader(systemImage: "hammer", title: "Developer Mode") {
                        statusBadge(enabled: devMode)
                    }
                    Toggle("Enable Developer Mode", isOn: $devMode)
                }

                if devMode {
                    PreferencesCard {
                        PreferencesCardHeader(systemImage: "gearshape.2", title: "Diagnostics")

                        Toggle("Enable Engine Comparison", isOn: $engineComparison)
                        Toggle("Force Latest Release as Update", isOn: $forceUpdateAvailable)

                        PreferencesCardCaption(text: "When enabled, Check for Updates shows the latest GitHub Release even if its version is not newer.")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(enabled: Bool) -> some View {
        Label(enabled ? "On" : "Off", systemImage: enabled ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(enabled ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(enabled ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1), in: Capsule())
    }
}

/// A selectable OCR recognition language. `code` is the compact identifier
/// stored in `ocrEnabledLanguages`; Vision resolves it to its full identifier.
private enum OCRLanguageOption: String, CaseIterable, Identifiable {
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
    case korean

    var id: String { code }

    var code: String {
        switch self {
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        case .japanese: return "ja"
        case .korean: return "ko"
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
}
