import SwiftUI
import KeyboardShortcuts
import SharedKit

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gear") }
            
            CapturePreferencesView()
                .tabItem { Label("Capture", systemImage: "camera") }
            
            OCRPreferencesView()
                .tabItem { Label("OCR", systemImage: "text.viewfinder") }
            
            ShortcutsPreferencesView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            
            HistoryPreferencesView()
                .tabItem { Label("History", systemImage: "clock") }
            
            DeveloperPreferencesView()
                .tabItem { Label("Developer", systemImage: "hammer") }
        }
        .padding()
        .frame(width: 500, height: 400)
        .background(.ultraThinMaterial)
    }
}

struct GeneralPreferencesView: View {
    @AppStorage("general_language") private var language = "system"
    @AppStorage("general_launchAtLogin") private var launchAtLogin = false
    
    var body: some View {
        Form {
            Picker("Language:", selection: $language) {
                Text("System Default").tag("system")
                Text("English").tag("en")
                Text("Chinese").tag("zh")
            }
            .pickerStyle(.menu)
            
            Toggle("Launch at login", isOn: $launchAtLogin)
        }
        .padding()
    }
}

struct CapturePreferencesView: View {
    @AppStorage("capture_defaultMode") private var defaultMode = "area"
    @AppStorage("capture_saveLocation") private var saveLocation = "clipboard"
    
    var body: some View {
        Form {
            Picker("Default Mode:", selection: $defaultMode) {
                Text("Area").tag("area")
                Text("Window").tag("window")
                Text("Fullscreen").tag("fullscreen")
            }
            .pickerStyle(.menu)
            
            Picker("Save Location:", selection: $saveLocation) {
                Text("Clipboard").tag("clipboard")
                Text("Desktop").tag("desktop")
                Text("Documents").tag("documents")
            }
            .pickerStyle(.menu)
        }
        .padding()
    }
}

struct OCRPreferencesView: View {
    @AppStorage("ocr_languagePriority") private var languagePriority = "auto"
    @AppStorage("ocr_confidenceThreshold") private var confidenceThreshold = 0.8
    @AppStorage("ocr_engine") private var engine = "vision"
    
    var body: some View {
        Form {
            Picker("Language Priority:", selection: $languagePriority) {
                Text("Auto Detect").tag("auto")
                Text("English First").tag("en")
                Text("Chinese First").tag("zh")
            }
            .pickerStyle(.menu)
            
            Picker("OCR Engine:", selection: $engine) {
                Text("Apple Vision").tag("vision")
                Text("Tesseract").tag("tesseract")
            }
            .pickerStyle(.menu)
            
            VStack(alignment: .leading) {
                Text("Confidence Threshold: \(Int(confidenceThreshold * 100))%")
                Slider(value: $confidenceThreshold, in: 0...1, step: 0.05)
            }
            .padding(.top, 8)
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
    @AppStorage("history_retentionPolicy") private var retentionPolicy = "30days"
    @AppStorage("history_storageSize") private var storageSize = 1.0
    @AppStorage("history_autoSave") private var autoSave = true
    @AppStorage("history_saveFullText") private var saveFullText = false
    
    var body: some View {
        Form {
            Picker("Retention Policy:", selection: $retentionPolicy) {
                Text("7 Days").tag("7days")
                Text("30 Days").tag("30days")
                Text("90 Days").tag("90days")
                Text("Forever").tag("forever")
            }
            .pickerStyle(.menu)
            
            VStack(alignment: .leading) {
                Text("Max Storage Size: \(storageSize, specifier: "%.1f") GB")
                Slider(value: $storageSize, in: 0.1...10.0, step: 0.1)
            }
            .padding(.top, 8)

            Toggle("Auto-save captures to history", isOn: $autoSave)
                .padding(.top, 8)
                .help("Automatically save screenshots and thumbnails to local encrypted history")

            if autoSave {
                Toggle("Save full OCR text", isOn: $saveFullText)
                    .help("Store complete OCR text in encrypted history entries. Off stores an empty text field.")
            }
        }
        .padding()
    }
}

struct DeveloperPreferencesView: View {
    @AppStorage("dev_devMode") private var devMode = false
    @AppStorage("dev_engineComparison") private var engineComparison = false
    
    var body: some View {
        Form {
            Toggle("Enable Developer Mode", isOn: $devMode)
            
            if devMode {
                Toggle("Enable Engine Comparison", isOn: $engineComparison)
            }
        }
        .padding()
    }
}
