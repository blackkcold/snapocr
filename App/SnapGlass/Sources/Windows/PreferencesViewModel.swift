import SwiftUI
import Combine

final class PreferencesViewModel: ObservableObject {
    @Published var defaultLanguage: String {
        didSet { UserDefaults.standard.set(defaultLanguage, forKey: "defaultLanguage") }
    }
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    @Published var autoCopyToClipboard: Bool {
        didSet { UserDefaults.standard.set(autoCopyToClipboard, forKey: "autoCopyToClipboard") }
    }
    @Published var defaultCaptureMode: String {
        didSet { UserDefaults.standard.set(defaultCaptureMode, forKey: "defaultCaptureMode") }
    }
    @Published var saveLocation: String {
        didSet { UserDefaults.standard.set(saveLocation, forKey: "saveLocation") }
    }
    @Published var ocrLanguagePriority: [String] {
        didSet { UserDefaults.standard.set(ocrLanguagePriority, forKey: "ocrLanguagePriority") }
    }
    @Published var ocrEngine: String {
        didSet { UserDefaults.standard.set(ocrEngine, forKey: "ocrEngine") }
    }
    @Published var confidenceThreshold: Double {
        didSet { UserDefaults.standard.set(confidenceThreshold, forKey: "confidenceThreshold") }
    }
    @Published var historyRetentionDays: Int {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: "historyRetentionDays") }
    }
    @Published var historyStorageSize: Double {
        didSet { UserDefaults.standard.set(historyStorageSize, forKey: "historyStorageSize") }
    }
    @Published var devModeEnabled: Bool {
        didSet { UserDefaults.standard.set(devModeEnabled, forKey: "devModeEnabled") }
    }
    
    init() {
        self.defaultLanguage = UserDefaults.standard.string(forKey: "defaultLanguage") ?? "en-US"
        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        self.autoCopyToClipboard = UserDefaults.standard.bool(forKey: "autoCopyToClipboard")
        self.defaultCaptureMode = UserDefaults.standard.string(forKey: "defaultCaptureMode") ?? "area"
        self.saveLocation = UserDefaults.standard.string(forKey: "saveLocation") ?? "~/Pictures/SnapGlass"
        self.ocrLanguagePriority = UserDefaults.standard.stringArray(forKey: "ocrLanguagePriority") ?? ["en-US", "zh-Hans"]
        self.ocrEngine = UserDefaults.standard.string(forKey: "ocrEngine") ?? "vision"
        self.confidenceThreshold = {
            let val = UserDefaults.standard.double(forKey: "confidenceThreshold")
            return val == 0 ? 0.8 : val
        }()
        self.historyRetentionDays = {
            let val = UserDefaults.standard.integer(forKey: "historyRetentionDays")
            return val == 0 ? 30 : val
        }()
        self.historyStorageSize = {
            let val = UserDefaults.standard.double(forKey: "historyStorageSize")
            return val == 0 ? 1.0 : val
        }()
        self.devModeEnabled = UserDefaults.standard.bool(forKey: "devModeEnabled")
    }
    
    func exportLogs() {
        print("Exporting logs...")
    }
}
