import AppKit
import CaptureCore

// MARK: - PinnedToolbarWindow

/// 悬浮工具条的窗口载体。
///
/// 采用独立子窗口而非面板内子视图，原因有二：
/// 1. 面板可被拖拽缩放到 `minimumResizeWidth`（40pt），子视图会被窗口裁剪而装不下工具条；
/// 2. 面板的透明度由窗口级 `alphaValue` 实现，子视图在 20% 不透明度下会一并变淡而无法操作，
///    独立窗口可完全避开既有的透明度实现。
@MainActor
final class PinnedToolbarWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, parentLevel: NSWindow.Level) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 与置顶面板同源：不进入录屏 / 系统截屏 / 后续 SnapGlass 截图。
        // `sharingType` 是**逐窗口**属性、不会被父窗口继承，必须显式设置。
        sharingType = .none
        // `level` 与 `collectionBehavior` 同样不继承，必须显式设置，
        // 否则切换 Space 或进入全屏时工具条会消失。
        level = NSWindow.Level(rawValue: parentLevel.rawValue + 1)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 排序操作可能重置 `sharingType`，排序后需重新确认内容保护。
    func reassertContentProtection() {
        sharingType = .none
    }
}

// MARK: - PinnedToolbarCoordinator

/// 协调置顶面板与其悬浮工具条：显隐时序、几何跟随、读数同步与生命周期回收。
///
/// 工具条与面板是两个独立窗口，鼠标从面板移向工具条必然触发面板的 `mouseExited`，
/// 因此隐藏必须延迟、并由工具条自身的进入事件取消——全部时序逻辑收敛到
/// `PinnedToolbarVisibility` 这一可在 CaptureCore 下单测的纯值类型。
@MainActor
final class PinnedToolbarCoordinator {
    private weak var panel: NSWindow?
    private let pinnedView: PinnedImageView

    private let toolbarWindow: PinnedToolbarWindow
    private let toolbarView = PinnedToolbarView(frame: .zero)
    private var toolbarSize: CGSize = .zero

    private var visibility = PinnedToolbarVisibility()
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// 创建协调器并完成全部接线。
    ///
    /// - Parameters:
    ///   - panel: 置顶面板。
    ///   - pinnedView: 面板内容视图，承载真实的透明度与缩放状态。
    init(panel: NSWindow, pinnedView: PinnedImageView) {
        self.panel = panel
        self.pinnedView = pinnedView

        let initialSize = CGSize(
            width: PinnedToolbarLayout.regular.minimumWidth,
            height: PinnedToolbarLayout.regular.minimumHeight
        )
        let window = PinnedToolbarWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            parentLevel: panel.level
        )
        self.toolbarWindow = window

        toolbarView.frame = NSRect(origin: .zero, size: initialSize)
        // 随窗口尺寸自适应，避免内容与窗口不一致。
        toolbarView.autoresizingMask = [.width, .height]
        window.contentView = toolbarView
        toolbarSize = initialSize

        wireToolbarCallbacks()
        wirePinnedViewCallbacks()
        observePanelGeometry()
    }

    /// 回收工具条窗口与全部观察者。
    ///
    /// 必须在面板关闭时调用，避免子窗口成为幽灵窗口。
    func invalidate() {
        showTask?.cancel()
        hideTask?.cancel()
        showTask = nil
        hideTask = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        hideImmediately()
        toolbarWindow.orderOut(nil)
        if let panel, toolbarWindow.parent === panel {
            panel.removeChildWindow(toolbarWindow)
        }
    }

    // MARK: - 接线

    private func wireToolbarCallbacks() {
        toolbarView.onInteractionChange = { [weak self] isInteracting in
            guard let self else { return }
            if isInteracting {
                self.visibility.interactionBegan()
            } else {
                self.visibility.interactionEnded()
            }
            self.scheduleHide()
        }
        toolbarView.onPointerEnter = { [weak self] in
            guard let self else { return }
            self.hideTask?.cancel()
            self.visibility.pointerEntered()
            self.scheduleShow()
        }
        toolbarView.onPointerExit = { [weak self] in
            guard let self else { return }
            self.visibility.pointerExited()
            self.scheduleHide()
        }
        toolbarView.onOpacityChange = { [weak self] opacity in
            self?.pinnedView.setOpacity(opacity)
        }
        toolbarView.onScaleChange = { [weak self] scale in
            self?.pinnedView.setScale(scale)
        }
        toolbarView.onResetSize = { [weak self] in
            guard let self else { return }
            self.pinnedView.resetToOriginalSize()
            self.syncReadouts()
        }
        toolbarView.onFitToScreen = { [weak self] in
            guard let self else { return }
            self.pinnedView.fitToScreen()
            self.syncReadouts()
        }
    }

    private func wirePinnedViewCallbacks() {
        pinnedView.onHoverChanged = { [weak self] isInside in
            guard let self else { return }
            if isInside {
                self.hideTask?.cancel()
                self.visibility.pointerEntered()
                self.scheduleShow()
            } else {
                self.showTask?.cancel()
                self.visibility.pointerExited()
                self.scheduleHide()
            }
        }
        pinnedView.onOpacityChanged = { [weak self] opacity in
            self?.toolbarView.updateOpacity(opacity)
        }
    }

    private func observePanelGeometry() {
        guard let panel else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reposition()
                }
            }
            observers.append(observer)
        }
    }

    // MARK: - 显隐时序

    private func scheduleShow() {
        showTask?.cancel()
        let delay = visibility.pendingShowDelay
        if delay <= 0 {
            visibility.applyShow()
            present()
            return
        }
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.visibility.applyShow()
            self.present()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard let delay = visibility.pendingHideDelay else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard self.visibility.applyHide() else { return }
            self.hideImmediately()
        }
    }

    private func present() {
        guard let panel else { return }
        if toolbarWindow.parent !== panel {
            panel.addChildWindow(toolbarWindow, ordered: .above)
        }
        syncReadouts()
        // 先定档位与尺寸（此刻视图已在窗口层级中），再定位，最后排序。
        // 顺序不能颠倒：定位依赖 `toolbarSize`，而排序会重置 `sharingType`。
        updateToolbarSize()
        // 必须先定位再排序：`updateToolbarFrame` 若像 `reposition()` 那样要求
        // `isVisible`，首次显示会在定位前被跳过，工具条就落在窗口初始原点
        // （屏幕左下），表现为严重偏移。
        updateToolbarFrame()
        toolbarWindow.orderFront(nil)
        // 排序可能重置 sharingType，必须在其后重新确认。
        toolbarWindow.reassertContentProtection()
    }

    /// 工具条可占用的宽度：屏幕可见宽度减去两侧留白。
    private func availableToolbarWidth() -> CGFloat {
        let panelFrame = panel?.frame ?? .zero
        let screenFrame = (panel?.screen ?? NSScreen.main)?.visibleFrame ?? panelFrame
        return max(0, screenFrame.width - 2 * PinnedImageGeometry.toolbarSpacing)
    }

    /// 按可用宽度选择档位并**测量**工具条尺寸。
    ///
    /// 宽度按档位的固定件加两根滑杆算出（滑杆在档位区间内吸收剩余宽度），高度取控件
    /// 固有高度并以档位下限兜底——不再硬编码 40pt，也不再只测宽度：旧实现把高度写死
    /// 为 40 而实测内容更低，导致窗口比内容矮、控件被圆角裁切而显示不全。
    private func updateToolbarSize() {
        let available = availableToolbarWidth()
        let layout = PinnedImageGeometry.toolbarLayout(availableWidth: available)
        toolbarView.apply(layout: layout)
        toolbarView.layoutSubtreeIfNeeded()

        let fitting = toolbarView.fittingSize
        let measuredHeight = fitting.height > 0 ? fitting.height : layout.minimumHeight
        // 兜底：内容高于测量值时以推导下限为准，宁可略高也绝不让窗口比内容矮（会裁切）。
        let contentHeight = max(measuredHeight, layout.minimumHeight)
        // 极端窄屏下内容仍可能超出可用宽度；`clampedToolbarWidth` 按可用宽度收窄，
        // 宁可让内容略微压缩也不让窗口溢出屏幕。
        let width = PinnedImageGeometry.clampedToolbarWidth(layout: layout, availableWidth: available)
        let size = PinnedImageGeometry.integralToolbarSize(
            CGSize(width: max(width, 1), height: contentHeight)
        )

        guard size != toolbarSize else { return }
        toolbarSize = size
        toolbarWindow.setContentSize(size)
    }

    private func hideImmediately() {
        toolbarWindow.orderOut(nil)
        if let panel, toolbarWindow.parent === panel {
            panel.removeChildWindow(toolbarWindow)
        }
    }

    // MARK: - 几何跟随

    /// 面板移动/缩放时的跟随。仅在工具条可见时有意义。
    private func reposition() {
        guard toolbarWindow.isVisible else { return }
        // 面板可能被拖到另一块屏幕，档位与可用宽度随之变化，需重新测量。
        updateToolbarSize()
        updateToolbarFrame()
    }

    /// 按当前面板 frame 计算并写入工具条 frame（不要求可见）。
    private func updateToolbarFrame() {
        guard let panel else { return }
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let frame = PinnedImageGeometry.toolbarPlacement(
            panelFrame: panel.frame,
            toolbarSize: toolbarSize,
            screenFrame: screenFrame
        )
        guard frame != .zero, frame != toolbarWindow.frame else { return }
        toolbarWindow.setFrame(frame, display: false)
    }

    // MARK: - 读数同步

    private func syncReadouts() {
        toolbarView.updateOpacity(pinnedView.currentOpacity)
        toolbarView.updateScale(pinnedView.currentScale)
    }
}
