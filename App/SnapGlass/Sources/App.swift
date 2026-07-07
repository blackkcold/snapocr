import SwiftUI
import AppKit
import SharedKit
import CaptureCore
import OCRCore
import BarcodeCore
import AnnotationCore
import ScrollCore
import HistoryCore
import AutomationCore
import KeyboardShortcuts

/// The main application entry point for SnapGlass.
@main
struct SnapGlassApp: App {
    /// The view model managing capture state and coordination.
    @StateObject private var viewModel = CaptureViewModel()
    
    /// App delegate adaptor for macOS 13 URL scheme handling.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    /// Environment value for opening windows.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("SnapGlass", systemImage: "camera.viewfinder") {
            MenuBarView()
                .environmentObject(viewModel)
                .onReceive(NotificationCenter.default.publisher(for: .snapGlassOpenURL)) { notification in
                    if let url = notification.object as? URL {
                        Task { await handleIncomingURL(url) }
                    }
                }
        }

        Window("Preferences", id: "preferences") {
            PreferencesView()
                .toast(message: $viewModel.toastMessage)
        }

        Window("History", id: "history") {
            HistoryView()
                .toast(message: $viewModel.toastMessage)
        }
        
        Window("Annotation Editor", id: "editor") {
            if let image = viewModel.editorImage {
                EditorView(image: image)
                    .frame(minWidth: 800, minHeight: 600)
                    .toast(message: $viewModel.toastMessage)
                    .onDisappear {
                        viewModel.editorImage = nil
                    }
            }
        }
        
        Window("Permission Required", id: "permission") {
            PermissionGuideView()
                .toast(message: $viewModel.toastMessage)
        }
        .windowResizability(.contentSize)

        Window("Automation", id: "automation") {
            RoutingView()
        }

        Settings {
            PreferencesView()
                .toast(message: $viewModel.toastMessage)
        }
    }
    
    init() {
        // Hotkeys are setup in CaptureViewModel
    }
}

// MARK: - URL Scheme Handling

extension SnapGlassApp {
    @MainActor
    private func handleIncomingURL(_ url: URL) async {
        let router = URLSchemeRouter()
        guard router.canHandle(url) else { return }
        
        do {
            let routeResult = try router.route(url)
            let command = routeResult.command
            
            switch command {
            case .capture(let mode, _):
                let captureMode = resolveCaptureMode(from: mode)
                let result = try await viewModel.captureOrchestrator.capture(
                    mode: captureMode,
                    options: CaptureOptions()
                )
                let path = saveCaptureToTemp(result.image)
                viewModel.showToast(message: "URL截图完成: \(path)", type: .success)
                
                if routeResult.ocrAfterCapture {
                    let ocrResult = try await viewModel.ocrPipeline.recognize(result.image)
                    viewModel.showToast(message: "OCR完成: \(ocrResult.text.prefix(80))...", type: .success)
                }
                
            case .ocr(let file, _, _, _, _):
                guard let image = loadCGImage(from: file) else {
                    viewModel.showToast(message: "文件未找到: \(file)", type: .error)
                    return
                }
                let ocrResult = try await viewModel.ocrPipeline.recognize(image)
                viewModel.showToast(message: "OCR完成: \(ocrResult.text.prefix(80))...", type: .success)
                
            case .barcode(let file, _, _):
                guard let image = loadCGImage(from: file) else {
                    viewModel.showToast(message: "文件未找到: \(file)", type: .error)
                    return
                }
                let results = try await viewModel.barcodeEngine.detect(in: image, types: [])
                if let first = results.first {
                    viewModel.showToast(message: "条码: \(first.payload)", type: .success)
                } else {
                    viewModel.showToast(message: "未检测到条码", type: .info)
                }
                
            default:
                viewModel.showToast(message: "命令已接收", type: .info)
            }
        } catch {
            viewModel.showToast(message: "URL处理失败: \(error.localizedDescription)", type: .error)
        }
    }
    
    private func resolveCaptureMode(from modeString: String?) -> CaptureCore.CaptureMode {
        switch modeString {
        case "area": return CaptureCore.CaptureMode.area(CGDisplayBounds(CGMainDisplayID()))
        case "window": return CaptureCore.CaptureMode.window(nil)
        default: return CaptureCore.CaptureMode.fullscreen
        }
    }
    
    private func saveCaptureToTemp(_ image: CGImage) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapglass-url-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return url.path
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url.path
    }
    
    private func loadCGImage(from path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - App Delegate

/// macOS 13 compatible URL scheme handler.
///
/// `.onOpenURL` on `MenuBarExtra` is only available from macOS 14,
/// so we use `NSApplicationDelegate` + `NotificationCenter` instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .snapGlassOpenURL, object: url)
        }
    }
}

extension Notification.Name {
    /// Notification posted when SnapGlass receives a URL scheme event.
    static let snapGlassOpenURL = Notification.Name("SnapGlassOpenURL")
}
