import AppKit
import Quartz

/// Thin wrapper around the system Quick Look panel.
///
/// The library only supplies file URLs; screenshots are decrypted to a
/// short-lived file by the view model before this is called.
@MainActor
final class LibraryQuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = LibraryQuickLookCoordinator()

    private var urls: [URL] = []

    private override init() {
        super.init()
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
