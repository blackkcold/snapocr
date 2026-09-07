import SwiftUI
import KeyboardShortcuts
import SharedKit
import HistoryCore
import ServiceManagement

struct PreferencesView: View {
    @EnvironmentObject private var router: PreferencesRouter
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
                            isSelected: section == router.selectedSection,
                            collapsed: isSidebarCollapsed
                        ) {
                            router.selectedSection = section
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
            PreferencesPageHeader(section: router.selectedSection)

            Divider()

            Group {
                switch router.selectedSection {
                case .general: GeneralPreferencesView()
                case .appearance: AppearancePreferencesView()
                case .capture: CapturePreferencesView()
                case .ocr: OCRPreferencesView()
                case .shortcuts: ShortcutsPreferencesView()
                case .history: HistoryPreferencesView()
                case .updates: UpdatesPreferencesView()
                case .about: AboutPreferencesView()
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
    @AppStorage(PreferenceKeys.pickerDominantColorCount)
    private var pickerDominantColorCount = PreferenceDefaults.pickerDominantColorCount
    
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
            TextEntryPreferencesView()
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

            Picker("Number of dominant colors", selection: $pickerDominantColorCount) {
                ForEach(3...6, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
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

                PreferencesCardCaption(text: LocalizedStringKey(
                    "Disable languages you rarely use to prevent visually similar characters "
                        + "(such as Japanese kanji and Chinese hanzi) from being misrecognized."
                ))
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

struct ShortcutsPreferencesView: View {    var body: some View {
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
