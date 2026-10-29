import AppKit
import BarcodeCore
import CaptureCore
import SharedKit

// MARK: - AreaTrackingView 条码识别

extension AreaTrackingView {
    /// 装配结果浮层：闭包全部指向本视图，浮层自己不做任何业务判断。
    func configureBarcodePanel() {
        barcodePanel.isHidden = true
        barcodePanel.onCopy = { [weak self] text in
            self?.copyScanPayload(text)
        }
        barcodePanel.onOpenLink = { [weak self] url in
            self?.openScanLink(url)
        }
        barcodePanel.onRescan = { [weak self] in
            self?.scanSelectedRegion(liveCapture: true)
        }
        barcodePanel.onCopyAll = { [weak self] in
            self?.copyAllScanPayloads()
        }
        barcodePanel.onClose = { [weak self] in
            _ = self?.dismissBarcodePanel()
        }
        addSubview(barcodePanel)
    }

    /// 识别当前选区。
    ///
    /// - Parameter liveCapture: `true` 时重新截屏（「重新识别」，能拿到动画码的
    ///   最新帧）；`false` 时用遮罩弹出前的预截原图，无时差、无闪烁。
    func scanSelectedRegion(liveCapture: Bool = false) {
        guard phase == .selected,
              selectionRect.width > 5, selectionRect.height > 5,
              !scanState.isScanning
        else { return }

        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        let quartzRect = selectionRects().quartz
        scanState = .scanning

        scanTask = Task { [weak self] in
            guard let self else { return }
            let image: CGImage?
            if liveCapture {
                image = await self.recaptureSelection(quartzRect)
            } else {
                image = self.precapturedSelectionImage(quartzRect: quartzRect)
            }

            guard !Task.isCancelled, generation == self.scanGeneration else { return }
            guard let image else {
                self.scanState = .failed(
                    AppLocalization.string(
                        "Capture failed: %@",
                        AppLocalization.string("No screenshot available")
                    )
                )
                return
            }

            do {
                let results = try await self.barcodeEngine.detect(in: image, types: [])
                guard !Task.isCancelled, generation == self.scanGeneration else { return }
                self.scanState = results.isEmpty ? .empty : .results(results)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == self.scanGeneration else { return }
                self.scanState = .failed(
                    AppLocalization.string(
                        "Barcode scan failed: %@",
                        error.localizedDescription
                    )
                )
            }
        }
    }

    /// 关闭浮层并取消进行中的识别。
    ///
    /// - Returns: 浮层原本是否可见（`esc` / `↵` 据此先处理浮层再处理动作栏）。
    @discardableResult
    func dismissBarcodePanel() -> Bool {
        guard scanState.isVisible else { return false }
        cancelScan()
        scanState = .idle
        return true
    }

    /// `↵` 在浮层可见时复制第一条识别内容。
    ///
    /// - Returns: 是否消费了这次回车（没有结果时交回动作栏复制图片）。
    @discardableResult
    func copyFirstScanPayload() -> Bool {
        guard case .results(let results) = scanState,
              let payload = BarcodePayloadFormatter.payloads(from: results).first
        else { return false }
        copyScanPayload(payload.text)
        return true
    }

    /// 打开识别到的链接。
    ///
    /// 遮罩是 `.screenSaver` 级别的全屏面板：不先收掉它，浏览器会被整块盖住，
    /// 看起来就是「按钮没反应」。所以先结束选区会话、关掉所有屏幕的遮罩，
    /// 再把 URL 交给系统；系统没有能处理它的应用时退回复制。
    func openScanLink(_ url: URL) {
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            copyScanPayload(url.absoluteString)
            NSSound.beep()
            return
        }

        cancelScan()
        scanState = .idle
        onSelectionComplete?(nil)
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开第一条链接结果（`⌘↵`）。
    @discardableResult
    func openFirstScanLink() -> Bool {
        guard case .results(let results) = scanState,
              let payload = BarcodePayloadFormatter.payloads(from: results).first,
              let url = payload.webLink
        else { return false }
        openScanLink(url)
        return true
    }

    /// 按扫描状态刷新浮层：`.idle` 隐藏，其余状态显示并重新贴靠动作栏。
    func refreshBarcodePanel() {
        guard phase == .selected, scanState.isVisible else {
            barcodePanel.isHidden = true
            return
        }
        let wasHidden = barcodePanel.isHidden
        barcodePanel.update(state: scanState)
        barcodePanel.isHidden = false
        positionBarcodePanel()
        if wasHidden {
            activateForScanPanel()
        }
    }

    /// 浮层一出现就请求激活，并把面板设为 key。
    ///
    /// 遮罩是 `.nonactivatingPanel`：少了这一步，进程一直是「非活跃」，
    /// 首次点击会被当成激活点击交给 `mouseDown`，按钮和正文都收不到事件。
    private func activateForScanPanel() {
        SystemApplicationActivationController().requestActivation()
        window?.makeKey()
    }

    /// 把浮层贴到动作栏外侧，并夹在屏幕范围内。
    ///
    /// 动作栏在选区下方时浮层更靠下，在上方时更靠上；那一侧放不下就翻到
    /// 另一侧，两侧都不够才居中——始终不出屏。
    func positionBarcodePanel() {
        guard !barcodePanel.isHidden else { return }
        let size = barcodePanel.preferredSize
        let inset: CGFloat = 8
        let margin: CGFloat = 8
        let barFrame = actionBar.frame

        let preferredX = barFrame.midX - size.width / 2
        let maximumX = max(bounds.minX + inset, bounds.maxX - size.width - inset)
        let originX = min(max(preferredX, bounds.minX + inset), maximumX)

        let spaceBelowBar = barFrame.minY - margin - (bounds.minY + inset)
        let spaceAboveBar = (bounds.maxY - inset) - (barFrame.maxY + margin)
        let spaceAboveSelection = (bounds.maxY - inset) - (selectionRect.maxY + margin)
        let spaceBelowSelection = selectionRect.minY - margin - (bounds.minY + inset)
        let barIsBelowSelection = barFrame.midY < selectionRect.midY

        let originY: CGFloat
        if barIsBelowSelection, spaceBelowBar >= size.height {
            originY = barFrame.minY - margin - size.height
        } else if !barIsBelowSelection, spaceAboveBar >= size.height {
            originY = barFrame.maxY + margin
        } else if barIsBelowSelection, spaceAboveSelection >= size.height {
            // 动作栏挤在选区下方、下面放不下时，翻到选区上方，避免压住选区。
            originY = selectionRect.maxY + margin
        } else if !barIsBelowSelection, spaceBelowSelection >= size.height {
            originY = selectionRect.minY - margin - size.height
        } else if spaceAboveBar >= size.height {
            originY = barFrame.maxY + margin
        } else if spaceBelowBar >= size.height {
            originY = barFrame.minY - margin - size.height
        } else {
            originY = bounds.midY - size.height / 2
        }
        let maximumY = max(bounds.minY + inset, bounds.maxY - size.height - inset)
        barcodePanel.frame = CGRect(
            origin: CGPoint(
                x: originX,
                y: min(max(originY, bounds.minY + inset), maximumY)
            ),
            size: size
        )
    }

    /// `s` 识别、`r` 重新识别（仅浮层可见时）。
    ///
    /// 带 ⌘/⌃/⌥ 的组合键交给既有快捷键逻辑，这里只处理裸按键。
    func handleScanShortcut(_ event: NSEvent) -> Bool {
        guard phase == .selected,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        switch characters {
        case "s":
            scanSelectedRegion()
            return true
        case "r" where scanState.isVisible:
            scanSelectedRegion(liveCapture: true)
            return true
        default:
            return false
        }
    }

    /// 浮层可见时的组合键：`⌘↵` 打开链接，`⌘C` 复制整条内容。
    ///
    /// `⌘C` 在正文有选中文本时不消费，交给字段编辑器复制选中的片段。
    func handleScanCommand(_ event: NSEvent) -> Bool {
        guard phase == .selected,
              scanState.isVisible,
              event.modifierFlags.contains(.command)
        else { return false }

        if event.keyCode == 36 || event.keyCode == 76 {
            return openFirstScanLink()
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "c" else { return false }
        guard !hasSelectedScanText() else { return false }
        return copyFirstScanPayload()
    }

    /// 取消进行中的识别任务（换选区、收动作栏、关浮层都会走这里）。
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
    }

    // MARK: - 图像来源

    /// 用遮罩弹出前的预截原图裁出选区，无时差、无闪烁。
    func precapturedSelectionImage(quartzRect: CGRect) -> CGImage? {
        guard
            let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID,
            let frame = capturedFrames[displayID]
        else { return nil }

        let displayFrame = CGDisplayBounds(displayID)
        guard let cropRect = RegionPixelMapping.pixelCropRect(
            areaRect: quartzRect,
            displayFrame: displayFrame,
            imageSize: CGSize(width: frame.width, height: frame.height)
        ) else { return nil }
        return frame.cropping(to: cropRect)
    }

    /// 重新截一次选区（`SCKAdapter` 的区域路径返回的已经是裁好的图）。
    private func recaptureSelection(_ quartzRect: CGRect) async -> CGImage? {
        guard let onRecaptureRegion else { return nil }
        return await onRecaptureRegion(quartzRect)
    }

    // MARK: - 复制

    private func hasSelectedScanText() -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }

    private func copyScanPayload(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        barcodePanel.markCopied(payload: text)
    }

    private func copyAllScanPayloads() {
        guard case .results(let results) = scanState,
              let text = BarcodePayloadFormatter.joinedText(from: results)
        else { return }
        copyScanPayload(text)
    }
}
