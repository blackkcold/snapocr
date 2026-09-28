import AppKit
import CaptureCore
import OCRCore
import SharedKit

// MARK: - PinnedWindowManager

@MainActor
final class PinnedWindowManager: NSObject, NSWindowDelegate {
    static let shared = PinnedWindowManager()

    private var panels: [PinnedImagePanel] = []
    /// 按面板标识索引的工具条协调器。
    ///
    /// 与 `panels` 同步增删：面板关闭时必须一并回收，否则工具条子窗口会成为幽灵窗口。
    /// 同样禁止扫描 `NSApp.windows`。
    private var toolbars: [ObjectIdentifier: PinnedToolbarCoordinator] = [:]
    private var ocrPipeline: OCRPipeline?
    private var toastHandler: ((String, ToastType) -> Void)?

    private override init() {
        super.init()
    }

    /// 注册 toast 回调，使置顶面板的复制/OCR 反馈走应用统一的 toast 通道。
    ///
    /// - Parameter handler: 接收消息与类型的回调。
    func setToastHandler(_ handler: @escaping (String, ToastType) -> Void) {
        toastHandler = handler
    }

    /// 创建置顶面板。
    ///
    /// 面板先同步建立（内存），历史写入由其调用方负责，二者相互独立：
    /// 历史配额已满时仍会展示置顶结果。
    ///
    /// - Parameters:
    ///   - image: 裁剪后的截图。
    ///   - displayScale: 图片像素宽与选区点宽的比值。
    ///   - pinRect: 选区在 AppKit 全局点坐标中的矩形。
    func pin(image: CGImage, displayScale: CGFloat, pinRect: CGRect) {
        let resolvedScale = displayScale > 0 ? displayScale : 1
        let baseFrame = PinnedImageGeometry.initialPinFrame(
            appKitRect: pinRect,
            imageSize: CGSize(width: image.width, height: image.height),
            displayScale: resolvedScale
        )
        let offset = PinnedImageGeometry.cascadeOffset(forIndex: panels.count)
        let candidate = baseFrame.offsetBy(dx: offset.x, dy: offset.y)
        let screen = Self.screen(containing: candidate)
        let frame = PinnedImageGeometry.fitToScreen(
            candidate,
            screenFrame: screen?.visibleFrame ?? candidate
        )

        let panel = PinnedImagePanel(contentRect: frame)
        panel.delegate = self

        let view = PinnedImageView(
            image: image,
            displayScale: resolvedScale,
            onRequestClose: { [weak panel] in panel?.close() },
            onCopyImage: { [weak self] in self?.copyImage(image) },
            onCopyOCRText: { [weak self] in self?.copyOCRText(from: image) },
            onCloseAll: { [weak self] in self?.closeAll() }
        )
        view.frame = CGRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.setFrame(frame, display: true)

        // 镜像 AreaSelectionSession.retainedSessions：NSPanel 默认
        // isReleasedWhenClosed，需显式持有直到 willClose 回收。
        panels.append(panel)
        // 工具条由管理器持有，并在同一 `willClose` 路径回收，避免子窗口泄漏。
        toolbars[ObjectIdentifier(panel)] = PinnedToolbarCoordinator(panel: panel, pinnedView: view)
        panel.orderFrontRegardless()
    }

    /// 关闭全部置顶面板。
    ///
    /// 仅遍历本管理器持有的面板，不扫描 `NSApp.windows`——选区面板同样是
    /// `NSPanel`，按类型过滤会误关它们。
    func closeAll() {
        let active = panels
        panels.removeAll()
        for panel in active {
            toolbars[ObjectIdentifier(panel)]?.invalidate()
            toolbars[ObjectIdentifier(panel)] = nil
            panel.delegate = nil
            panel.close()
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? PinnedImagePanel else { return }
        Task { @MainActor [weak self] in
            self?.toolbars[ObjectIdentifier(closing)]?.invalidate()
            self?.toolbars[ObjectIdentifier(closing)] = nil
            self?.panels.removeAll { $0 === closing }
        }
    }

    private func copyImage(_ image: CGImage) {
        let nsImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([nsImage]) else {
            presentToast(AppLocalization.string("Unable to copy image"), type: .error)
            return
        }
        presentToast(AppLocalization.string("Screenshot copied to clipboard"), type: .success)
    }

    private func copyOCRText(from image: CGImage) {
        presentToast(AppLocalization.string("Recognizing text…"), type: .info)
        let pipeline = ocrPipeline ?? OCRPipeline()
        ocrPipeline = pipeline
        Task { @MainActor [weak self] in
            do {
                let result = try await pipeline.recognize(image)
                guard !result.text.isEmpty else {
                    self?.presentToast(AppLocalization.string("No text found"), type: .info)
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.text, forType: .string)
                self?.presentToast(AppLocalization.string("Text copied to clipboard"), type: .success)
            } catch {
                self?.presentToast(
                    AppLocalization.string("OCR failed: %@", error.localizedDescription),
                    type: .error
                )
            }
        }
    }

    private func presentToast(_ message: String, type: ToastType) {
        toastHandler?(message, type)
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }
}
