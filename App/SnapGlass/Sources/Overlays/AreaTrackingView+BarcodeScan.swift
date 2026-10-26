import AppKit
import BarcodeCore
import CaptureCore
import SharedKit

// MARK: - 选区条码识别状态

/// 动作栏「识别」按钮驱动的状态机。
///
/// 识别是只读的：不产生截图产物、不写历史、不碰剪贴板（直到用户点复制）。
enum ScanState {
    /// 没有浮层。
    case idle
    /// 识别中。
    case scanning
    /// 有结果（引擎顺序 = 置信度降序）。
    case results([BarcodeResult])
    /// 选区内没有条码。
    case empty
    /// 识别或截图失败。
    case failed(String)

    /// 是否需要在选区上显示浮层。
    var isVisible: Bool {
        if case .idle = self { return false }
        return true
    }

    /// 是否处于识别中（动作栏按钮据此禁用）。
    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
}

// MARK: - AreaTrackingView 条码识别

extension AreaTrackingView {
    /// 装配结果浮层：闭包全部指向本视图，浮层自己不做任何业务判断。
    func configureBarcodePanel() {
        barcodePanel.isHidden = true
        barcodePanel.onCopy = { [weak self] text in
            self?.copyScanPayload(text)
        }
        barcodePanel.onOpenLink = { url in
            NSWorkspace.shared.open(url)
        }
        barcodePanel.onRescan = { [weak self] in
            self?.scanSelectedRegion(liveCapture: true)
        }
        barcodePanel.onCopyAll = { [weak self] in
            self?.copyAllScanPayloads()
        }
        addSubview(barcodePanel)
    }

    /// 识别当前选区。
    ///
    /// - Parameter liveCapture: `true` 时重新截屏（「重新识别」，能拿到动画码的
    ///   最新帧）；`false` 时用遮罩弹出前的预截原图，无时差、无闪烁。
    func scanSelectedRegion(liveCapture: Bool = false) {
        guard phase == .choosingAction,
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

    /// 按扫描状态刷新浮层：`.idle` 隐藏，其余状态显示并重新贴靠动作栏。
    func refreshBarcodePanel() {
        guard phase == .choosingAction, scanState.isVisible else {
            barcodePanel.isHidden = true
            return
        }
        barcodePanel.update(state: scanState)
        barcodePanel.isHidden = false
        positionBarcodePanel()
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

        var originY: CGFloat
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
        originY = min(max(originY, bounds.minY + inset), maximumY)

        barcodePanel.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// `s` 识别、`r` 重新识别（仅浮层可见时）。
    ///
    /// 带 ⌘/⌃/⌥ 的组合键交给既有快捷键逻辑，这里只处理裸按键。
    func handleScanShortcut(_ event: NSEvent) -> Bool {
        guard phase == .choosingAction,
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
