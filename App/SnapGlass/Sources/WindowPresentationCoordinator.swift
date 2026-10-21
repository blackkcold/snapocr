import AppKit
import Foundation
import SharedKit

@MainActor
final class WindowPresentationCoordinator {
    static let shared: WindowPresentationCoordinator = {
        let activationController = SystemApplicationActivationController()
        return WindowPresentationCoordinator(
            activationController: activationController,
            focuser: SystemWindowFocuser(activation: activationController)
        )
    }()

    private final class WindowReference {
        weak var value: NSWindow?
        let token: ObjectIdentifier
        let id: String

        init(_ value: NSWindow, id: String) {
            self.value = value
            self.token = ObjectIdentifier(value)
            self.id = id
        }
    }

    private struct WindowObservers {
        let didMiniaturize: NSObjectProtocol
        let didDeminiaturize: NSObjectProtocol
    }

    private let activationController: ApplicationActivationControlling
    private let presentationTimeout: Duration
    private let reevaluateRetryInterval: Duration
    private let reevaluateRetryBudget: Duration
    private let focuser: WindowFocusing
    private let notificationCenter: NotificationCenter
    #if DEBUG
    private let logger = Logger(category: "window-lifecycle", logLevel: .debug)
    #else
    private let logger = Logger(category: "window-lifecycle", logLevel: .info)
    #endif
    private var lifecycleState = WindowLifecycleState()
    private var windows: [String: WindowReference] = [:]
    /// 逻辑 ID 当前映射之外，另按窗口 token 保留一份弱身份记录：窗口关闭后 SwiftUI
    /// 可能复用同一 `NSWindow` 而不再调用 `register()`，只有 token 记录能让协调器
    /// 认出“还是那扇窗”，从而在第二次关闭时仍然降级。
    private var knownWindowsByToken: [ObjectIdentifier: WindowReference] = [:]
    private var observedWindows: [ObjectIdentifier: WindowObservers] = [:]
    private var applicationObservers: [NSObjectProtocol] = []
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var reevaluateTask: Task<Void, Never>?

    init(
        activationController: ApplicationActivationControlling,
        presentationTimeout: Duration = .seconds(3),
        notificationCenter: NotificationCenter = .default,
        focuser: WindowFocusing? = nil,
        reevaluateRetryInterval: Duration = .milliseconds(100),
        reevaluateRetryBudget: Duration = .seconds(1)
    ) {
        self.activationController = activationController
        self.presentationTimeout = presentationTimeout
        self.notificationCenter = notificationCenter
        self.reevaluateRetryInterval = reevaluateRetryInterval
        self.reevaluateRetryBudget = reevaluateRetryBudget
        self.focuser = focuser ?? SystemWindowFocuser(activation: activationController)
        installApplicationObservers()
    }

    func present(id: String, open: () -> Void) {
        purgeStaleWindows()
        logger.info(
            "present.request id=\(id) policy=\(activationController.activationPolicy.rawValue) "
                + "active=\(activationController.isActive) \(lifecycleSummary)"
        )

        if let window = registeredWindow(id: id),
           window.isVisible,
           window.isKeyWindow,
           activationController.isActive {
            logger.info("present.noop id=\(id) reason=already-key")
            return
        }

        let presentation = lifecycleState.beginPresentation(id: id)
        let policyChanged = ensureRegularPolicy()
        if !policyChanged {
            logger.warning("policy.regular.failed id=\(id)")
        }

        if let window = registeredWindow(id: id), window.isVisible || window.isMiniaturized {
            // 已注册且仍存活的窗口：事件驱动聚焦，等应用真正 active 后再前置，
            // 不与异步激活在同一 runloop tick 竞争（第二次点击丢焦点的根因）。
            logger.info("present.focus id=\(id) generation=\(presentation.generation) source=registered")
            focuser.focus(window)
        } else {
            activationController.requestActivation()
            logger.info(
                "present.activate id=\(id) generation=\(presentation.generation) "
                    + "new=\(presentation.isNew) policyReady=\(policyChanged)"
            )

            if presentation.isNew {
                if windows[id] != nil {
                    // 注册过但不可见也未最小化 → 关闭后残留的僵尸窗口：
                    // 移除引用并重走 open()，避免把死窗口顶到前台。
                    logger.info(
                        "present.remove-stale id=\(id) generation=\(presentation.generation)"
                    )
                    removeStaleWindow(id: id)
                }
                logger.info("present.open id=\(id) generation=\(presentation.generation)")
                open()
            } else {
                logger.info(
                    "present.wait id=\(id) generation=\(presentation.generation) "
                        + "reason=open-in-flight"
                )
            }
        }

        scheduleTimeoutIfNeeded(id: id, generation: presentation.generation)
    }

    func register(_ window: NSWindow?, id: String) {
        guard let window else {
            logger.info("window.register.defer id=\(id) reason=no-window")
            purgeStaleWindows()
            reevaluateActivationPolicy()
            return
        }

        let reference = WindowReference(window, id: id)
        knownWindowsByToken[reference.token] = reference
        if windows[id]?.token != reference.token {
            if let previousReference = windows[id] {
                removeObservers(token: previousReference.token)
                logger.debug("window.replace id=\(id)")
            }
            windows[id] = reference
            lifecycleState.registerWindow(id: id)
            logger.info("window.register id=\(id) \(lifecycleSummary)")
        }
        observeWindow(window, token: reference.token)

        if window.isKeyWindow {
            handleDidBecomeKey(id: id, token: reference.token)
        }

        if lifecycleState.isPresentationPending(id: id) {
            _ = ensureRegularPolicy()
            logger.info("window.focus id=\(id) source=registration")
            focuser.focus(window)
        }
    }

    private func registeredWindow(id: String) -> NSWindow? {
        guard let reference = windows[id], let window = reference.value else {
            removeStaleWindow(id: id)
            return nil
        }
        return window
    }

    private func ensureRegularPolicy() -> Bool {
        if activationController.activationPolicy == .regular {
            return true
        }
        let result = activationController.setActivationPolicy(.regular)
        logger.info("policy.regular result=\(result)")
        return result
    }

    /// 应用级监听只在协调器生命周期内安装一次。窗口关闭后 SwiftUI 可能复用同一
    /// `NSWindow` 实例而不再走 `register()`，逐窗口观察此时已被移除，若没有应用级
    /// 监听，第二次关闭就永远不会触发降级。
    private func installApplicationObservers() {
        let center = notificationCenter

        applicationObservers.append(
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.logger.debug("window.close.unknown-object")
                        self.scheduleReevaluate()
                    }
                    return
                }
                let token = ObjectIdentifier(window)
                Task { @MainActor [weak self] in
                    self?.handleApplicationWillClose(token: token)
                }
            }
        )

        applicationObservers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                let token = ObjectIdentifier(window)
                Task { @MainActor [weak self] in
                    self?.handleApplicationDidBecomeKey(window: window, token: token)
                }
            }
        )
    }

    private func handleApplicationWillClose(token: ObjectIdentifier) {
        guard let id = knownWindowsByToken[token]?.id else {
            logger.debug("window.close.unknown")
            scheduleReevaluate()
            return
        }
        handleWillClose(id: id, token: token)
    }

    /// 成为 key 是一次幂等的重新登记机会：复用同一 `NSWindow` 重新打开时，
    /// SwiftUI 不保证再次调用 `register()`，靠这里恢复当前映射并补回逐窗口观察。
    private func handleApplicationDidBecomeKey(window: NSWindow, token: ObjectIdentifier) {
        guard let reference = knownWindowsByToken[token] else { return }
        observeWindow(window, token: token)
        if windows[reference.id]?.token != token {
            windows[reference.id] = reference
            lifecycleState.registerWindow(id: reference.id)
            logger.info("window.reregister id=\(reference.id) \(lifecycleSummary)")
        }
        handleDidBecomeKey(id: reference.id, token: token)
    }

    private func observeWindow(_ window: NSWindow, token: ObjectIdentifier) {
        guard observedWindows[token] == nil else { return }
        let center = notificationCenter

        let didMiniaturize = center.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReevaluate()
            }
        }

        let didDeminiaturize = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReevaluate()
            }
        }

        observedWindows[token] = WindowObservers(
            didMiniaturize: didMiniaturize,
            didDeminiaturize: didDeminiaturize
        )
    }

    private func handleDidBecomeKey(id: String, token: ObjectIdentifier) {
        guard windows[id]?.token == token else {
            logger.debug("window.key.ignored id=\(id) reason=stale")
            return
        }
        lifecycleState.completePresentation(id: id)
        cancelTimeout(id: id)
        // 窗口成为 key 即用户可见，补齐晋升到 regular 的对称路径。
        _ = ensureRegularPolicy()
        logger.info("window.key id=\(id) \(lifecycleSummary)")
    }

    private func handleWillClose(id: String, token: ObjectIdentifier) {
        removeObservers(token: token)

        if let reference = windows[id], reference.token == token {
            windows[id] = nil
            lifecycleState.unregisterWindow(id: id)
            lifecycleState.completePresentation(id: id)
            cancelTimeout(id: id)
            logger.info("window.close id=\(id) \(lifecycleSummary)")
        } else if windows[id] != nil {
            // 旧窗口迟到的关闭通知：新实例仍在使用这个逻辑 ID，不能清除映射。
            logger.debug("window.close.ignored id=\(id) reason=replaced")
        } else {
            logger.info("window.close.repeat id=\(id) \(lifecycleSummary)")
        }

        // 已知、未知与 stale 关闭都必须重排一次重算；是否降级仍由 pending
        // 和实际可见窗口决定，事件本身不做判断。
        scheduleReevaluate()
    }

    /// 合并同一 runloop tick 内的多次重算请求：`willClose` 触发时窗口仍 `isVisible`，
    /// 先让出一个 tick 等 `orderOut`，随后在有限预算内有条件地等待可见窗消失。
    /// 单拍等待会在关闭慢一拍时永久丢掉落级；有界的条件等待则保证降级不依赖
    /// “下一拍恰好已不可见”这个巧合，也不会在窗口真实存续时死循环。
    private func scheduleReevaluate() {
        guard reevaluateTask == nil else { return }
        reevaluateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            var waited: Duration = .zero
            while self.activationController.hasVisibleUserFacingWindow,
                waited < self.reevaluateRetryBudget {
                try? await Task.sleep(for: self.reevaluateRetryInterval)
                if Task.isCancelled {
                    self.reevaluateTask = nil
                    return
                }
                waited += self.reevaluateRetryInterval
            }
            self.reevaluateTask = nil
            self.purgeStaleWindows()
            self.reevaluateActivationPolicy()
        }
    }

    private func scheduleTimeoutIfNeeded(id: String, generation: Int) {
        guard lifecycleState.isCurrentPresentation(id: id, generation: generation) else { return }
        guard timeoutTasks[id] == nil else { return }

        timeoutTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.presentationTimeout ?? .seconds(3))
            } catch {
                return
            }
            guard let self else { return }
            self.handlePresentationTimeout(id: id, generation: generation)
        }
    }

    private func handlePresentationTimeout(id: String, generation: Int) {
        guard lifecycleState.isCurrentPresentation(id: id, generation: generation) else {
            timeoutTasks[id] = nil
            return
        }

        // 最后补救：聚焦没有按时完成、但窗口其实已就位且可用的情形——典型是
        // openWindow 复用旧 NSWindow 而没有再次触发 register 的路径，focus 只靠
        // register 就没有第二次机会。
        // 仅在应用已 active、窗口可见且未成 key 时补一次。
        if activationController.isActive,
            let window = registeredWindow(id: id),
            window.isVisible,
            !window.isKeyWindow {
            logger.info("present.timeout.focus id=\(id) generation=\(generation)")
            focuser.focus(window)
        }

        lifecycleState.completePresentation(id: id, generation: generation)
        timeoutTasks[id] = nil
        logger.warning("present.timeout id=\(id) generation=\(generation) \(lifecycleSummary)")
        purgeStaleWindows()
        reevaluateActivationPolicy()
    }

    private func cancelTimeout(id: String) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
    }

    private func purgeStaleWindows() {
        let staleIDs = windows.compactMap { id, reference in
            reference.value == nil ? id : nil
        }

        for id in staleIDs {
            removeStaleWindow(id: id)
        }

        // 已释放窗口的弱身份记录与残留逐窗口观察一并清理，避免重复开关无限累积。
        let deadTokens = knownWindowsByToken.compactMap { token, reference in
            reference.value == nil ? token : nil
        }

        for token in deadTokens {
            knownWindowsByToken[token] = nil
            removeObservers(token: token)
        }
    }

    private func removeStaleWindow(id: String) {
        guard let reference = windows.removeValue(forKey: id) else { return }
        lifecycleState.unregisterWindow(id: id)
        removeObservers(token: reference.token)
        if reference.value == nil {
            knownWindowsByToken[reference.token] = nil
        }
        logger.info("window.remove-stale id=\(id) \(lifecycleSummary)")
    }

    private func removeObservers(token: ObjectIdentifier) {
        guard let observers = observedWindows.removeValue(forKey: token) else { return }
        notificationCenter.removeObserver(observers.didMiniaturize)
        notificationCenter.removeObserver(observers.didDeminiaturize)
    }

    private func reevaluateActivationPolicy() {
        guard lifecycleState.shouldUseAccessoryPolicy else {
            logger.debug("policy.accessory.defer \(lifecycleSummary)")
            return
        }
        guard !activationController.hasVisibleUserFacingWindow else {
            logger.info("policy.accessory.defer reason=visible-window \(lifecycleSummary)")
            return
        }
        guard activationController.activationPolicy != .accessory else { return }
        let result = activationController.setActivationPolicy(.accessory)
        if result {
            // 应用仍处于 active 时切换 .accessory 常不能立即移除 Dock 图标，
            // 需显式 deactivate 才会生效。
            activationController.deactivate()
            logger.info("policy.accessory result=true")
        } else {
            logger.warning("policy.accessory result=false")
        }
    }

    #if DEBUG
    struct TrackedWindowCounts: Equatable {
        let mapped: Int
        let known: Int
        let observed: Int
    }

    /// 测试用：确认关闭/释放后当前映射、身份记录与逐窗口观察都不会无限累积。
    var trackedWindowCounts: TrackedWindowCounts {
        TrackedWindowCounts(
            mapped: windows.count,
            known: knownWindowsByToken.count,
            observed: observedWindows.count
        )
    }
    #endif

    private var lifecycleSummary: String {
        let registered = lifecycleState.registeredWindowIDs.sorted().joined(separator: ",")
        let pending = lifecycleState.pendingPresentations
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        return "registered=[\(registered)] pending=[\(pending)]"
    }
}
