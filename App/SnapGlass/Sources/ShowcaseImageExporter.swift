#if DEBUG
    import AppKit
    import CaptureCore
    import SharedKit
    import SwiftUI

    /// Renders the app's real views offscreen into documentation PNGs.
    ///
    /// Runs only in debug builds launched with `SNAPGLASS_SHOWCASE=1` and
    /// `SNAPGLASS_SHOWCASE_OUT=<directory>`; it renders, writes the files, then
    /// quits. Nothing here is reachable from a release build.
    @MainActor
    enum ShowcaseImageExporter {
        static func runIfConfigured() {
            guard ShowcaseMode.isEnabled,
                let output = ProcessInfo.processInfo.environment["SNAPGLASS_SHOWCASE_OUT"]
            else { return }

            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                export(to: directory)
                NSApp.terminate(nil)
            }
        }

        private static func export(to directory: URL) {
            let cards = demoCards()
            let layout = shelfLayout(cards: cards)
            let shelfSize = layout.panelSize

            write(
                hostedImage(
                    shelfView(
                        cards: cards, layout: layout,
                        configure: { model in
                            model.setPointerForShowcase(inside: true, location: CGPoint(x: 8, y: 6))
                        }),
                    size: shelfSize
                ),
                name: "shelf-default.png",
                to: directory
            )

            write(
                hostedImage(
                    shelfView(
                        cards: cards, layout: layout,
                        configure: { model in
                            model.setFocusedCapture(cards[1].captureID)
                            model.setPointerForShowcase(inside: true, location: CGPoint(x: 8, y: 6))
                        }),
                    size: shelfSize
                ),
                name: "shelf-keyboard.png",
                to: directory
            )

            write(dragComposite(cards: cards, layout: layout), name: "shelf-drag.png", to: directory)
            write(render(ocrToastView()), name: "ocr-actions.png", to: directory)
            write(render(actionBarView()), name: "action-bar.png", to: directory)
            write(shareAppearanceImage(), name: "share-appearance.png", to: directory)
            write(recordingStageImage(), name: "recording-hud.png", to: directory)

            let window = demoEditorImage()
            if let window {
                write(window, name: "window-before.png", to: directory)
                if let styled = WindowScreenshotStyling.apply(window, style: .standard(scale: 2)) {
                    write(styled, name: "window-styled.png", to: directory)
                }
            }
        }

        // MARK: - Shelf

        private static func shelfView(
            cards: [ScreenshotShelfCard],
            layout: ScreenshotShelfLayout,
            configure: (ScreenshotShelfViewModel) -> Void
        ) -> some View {
            let model = ScreenshotShelfViewModel(layout: layout)
            configure(model)
            return ScreenshotShelfView(model: model)
        }

        private static func dragComposite(
            cards: [ScreenshotShelfCard],
            layout: ScreenshotShelfLayout
        ) -> CGImage? {
            let dragged = cards[1]
            let metrics = layout.metrics
            let startX = metrics.shadowInset + layout.cardWidths[0] + metrics.cardSpacing
            let translation = CGSize(width: 22, height: -18)
            let preview = ScreenshotShelfDragPreview(
                cardID: dragged.captureID,
                startIndex: 1,
                startX: startX,
                width: layout.cardWidths[1],
                translation: translation,
                rotation: -3
            )

            let shelfModel = ScreenshotShelfViewModel(layout: layout)
            shelfModel.setDragPreviewForShowcase(preview)
            shelfModel.setPointerForShowcase(inside: true, location: CGPoint(x: 240, y: 70))
            guard
                let shelf = hostedImage(
                    ScreenshotShelfView(model: shelfModel),
                    size: layout.panelSize
                )
            else { return nil }

            let overlayModel = ScreenshotShelfDragOverlayModel()
            overlayModel.content = ScreenshotShelfDragOverlayContent(
                card: dragged,
                cardWidth: layout.cardWidths[1],
                cardHeight: layout.cardHeight,
                imageOpacity: layout.imageOpacity,
                rotation: preview.rotation,
                locale: layout.locale
            )
            guard let overlay = render(ScreenshotShelfDragOverlayView(model: overlayModel)) else {
                return nil
            }

            let cardTopLeft = CGPoint(
                x: startX + translation.width,
                y: layout.cardTopOffset + translation.height
            )
            return composite(
                shelf: shelf,
                overlay: overlay,
                overlayCardTopLeft: cardTopLeft,
                scale: 2
            )
        }

        private static func composite(
            shelf: NSImage,
            overlay: NSImage,
            overlayCardTopLeft: CGPoint,
            scale: CGFloat
        ) -> CGImage? {
            let topMargin: CGFloat = 96
            let canvasWidth = shelf.size.width
            let canvasHeight = shelf.size.height + topMargin
            let pixelWidth = Int(canvasWidth * scale)
            let pixelHeight = Int(canvasHeight * scale)

            guard
                let context = CGContext(
                    data: nil,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                let shelfImage = shelf.cgImage(forProposedRect: nil, context: nil, hints: nil),
                let overlayImage = overlay.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }

            let shelfRect = CGRect(
                x: 0,
                y: CGFloat(pixelHeight) - (topMargin + shelf.size.height) * scale,
                width: shelf.size.width * scale,
                height: shelf.size.height * scale
            )
            context.draw(shelfImage, in: shelfRect)

            let padding = ScreenshotShelfDragOverlayView.padding
            let cardInsetY = padding + ScreenshotShelfMetrics.hangerHeight
            let overlayTopLeft = CGPoint(
                x: overlayCardTopLeft.x - padding,
                y: topMargin + overlayCardTopLeft.y - cardInsetY
            )
            let overlayRect = CGRect(
                x: overlayTopLeft.x * scale,
                y: CGFloat(pixelHeight) - (overlayTopLeft.y + overlay.size.height) * scale,
                width: overlay.size.width * scale,
                height: overlay.size.height * scale
            )
            context.draw(overlayImage, in: overlayRect)

            return context.makeImage()
        }

        private static func shelfLayout(cards: [ScreenshotShelfCard]) -> ScreenshotShelfLayout {
            let metrics = ScreenshotShelfMetrics()
            let cardWidth: CGFloat = 168
            let cardHeight: CGFloat = 108
            let widths = Array(repeating: cardWidth, count: cards.count)
            let size = CGSize(
                width: metrics.panelWidth(cardWidths: widths),
                height: metrics.panelHeight(cardHeight: cardHeight)
            )
            return ScreenshotShelfLayout(
                cards: cards,
                cardWidths: widths,
                panelFrame: CGRect(origin: .zero, size: size),
                cardHeight: cardHeight,
                imageOpacity: PreferenceDefaults.screenshotShelfImageOpacity,
                locale: Locale(identifier: "zh-Hans"),
                metrics: metrics,
                anchor: .top
            )
        }

        private static func demoCards() -> [ScreenshotShelfCard] {
            (0..<3).map { index in
                ScreenshotShelfCard(
                    captureID: UUID(),
                    historyID: nil,
                    imagePixelSize: CGSize(width: 960, height: 600),
                    displayScale: 2,
                    scaleSourcePixelWidth: 960,
                    thumbnailData: nil,
                    decodedThumbnail: demoThumbnail(index: index),
                    errorMessage: nil,
                    feedbackMessage: nil
                )
            }
        }

        // MARK: - OCR toast

        private static func ocrToastView() -> some View {
            let message = ToastMessage(
                message: "文本中发现验证码",
                type: .info,
                actionLabel: "复制验证码",
                action: {}
            )
            return ToastView(message: message)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .padding(32)
        }

        // MARK: - Action bar mock

        private struct ActionBarItem: Identifiable {
            let id = UUID()
            let title: String
            let symbol: String
            let shortcut: String
        }

        private static func actionBarView() -> some View {
            let items = [
                ActionBarItem(title: "复制图片", symbol: "doc.on.doc", shortcut: "↵"),
                ActionBarItem(title: "识别条码", symbol: "qrcode.viewfinder", shortcut: "S"),
                ActionBarItem(title: "编辑截图", symbol: "pencil.and.outline", shortcut: "E"),
                ActionBarItem(title: "置顶图片", symbol: "pin", shortcut: "⌘P"),
            ]

            return HStack(spacing: 16) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(item.shortcut)
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.5)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0.16))
            )
            .shadow(color: .black.opacity(0.28), radius: 14, y: 7)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .padding(36)
        }

        // MARK: - Share appearance

        private static func shareAppearanceImage() -> NSImage? {
            guard let image = demoEditorImage() else { return nil }
            let context = EditorCaptureContext.capture(
                image: image,
                captureMode: "window",
                mockupStyle: MockupPreset.ocean.style
            )
            let viewModel = EditorViewModel(image: image, context: context)
            viewModel.inspectorTab = .share
            viewModel.setShareAppearanceEnabled(true)
            if let style = viewModel.mockupStyle,
                let preview = MockupRenderer.render(image, style: style)
            {
                viewModel.sharePreview = preview
                viewModel.sharePreviewState = .ready
            }

            let defaults = UserDefaults.standard
            let oldInspector = defaults.object(forKey: PreferenceKeys.editorInspectorVisible)
            let oldPreview = defaults.object(forKey: PreferenceKeys.editorShareCanvasPreview)
            defaults.set(true, forKey: PreferenceKeys.editorInspectorVisible)
            defaults.set(true, forKey: PreferenceKeys.editorShareCanvasPreview)
            defer {
                restore(oldInspector, forKey: PreferenceKeys.editorInspectorVisible)
                restore(oldPreview, forKey: PreferenceKeys.editorShareCanvasPreview)
            }

            let view = EditorView(viewModel: viewModel, context: context)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
            return hostedImage(
                view,
                size: CGSize(width: 1280, height: 800),
                background: .windowBackgroundColor,
                settle: 0.8
            )
        }

        // MARK: - Recording HUD

        private static func recordingStageImage() -> NSImage? {
            guard let image = demoEditorImage() else { return nil }
            let model = RecordingControlPanelModel(
                state: .recording(startedAt: Date().addingTimeInterval(-12)),
                surfaceOpacity: 1,
                hoverRestore: false
            )
            let actions = RecordingControlPanelActions(
                onCancel: {},
                onStop: {},
                onRetry: {},
                onReveal: { _ in },
                onDismiss: {},
                onHideWhileSaving: {},
                onCornerChange: { _ in },
                onToggleAudioDetails: {},
                onPreview: {},
                onStopPreview: {},
                onOpenLatest: { _ in },
                onOpenRecordings: {},
                onJoinExport: {}
            )
            let view = RecordingStageView(
                windowImage: nsImage(from: image),
                model: model,
                actions: actions
            )
            return hostedImage(
                view,
                size: CGSize(width: 1200, height: 760),
                background: .black,
                settle: 0.2
            )
        }

        // MARK: - Artwork

        private static func demoThumbnail(index: Int) -> CGImage? {
            guard let image = render(DemoThumbnailView(index: index), scale: 1) else { return nil }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        private static func mockWindowImage() -> CGImage? {
            let width = 760
            let height = 480
            guard
                let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }

            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 46, width: width, height: 46))

            let lights: [(CGFloat, CGColor)] = [
                (28, CGColor(red: 0.98, green: 0.37, blue: 0.34, alpha: 1)),
                (52, CGColor(red: 0.98, green: 0.74, blue: 0.25, alpha: 1)),
                (76, CGColor(red: 0.35, green: 0.79, blue: 0.35, alpha: 1)),
            ]
            for (offsetX, color) in lights {
                context.setFillColor(color)
                context.fillEllipse(
                    in: CGRect(x: offsetX, y: CGFloat(height) - 29, width: 12, height: 12)
                )
            }

            context.setFillColor(CGColor(gray: 0.86, alpha: 1))
            context.fill(CGRect(x: 40, y: 300, width: 300, height: 22))
            context.setFillColor(CGColor(gray: 0.92, alpha: 1))
            context.fill(CGRect(x: 40, y: 250, width: 680, height: 14))
            context.fill(CGRect(x: 40, y: 222, width: 560, height: 14))
            context.fill(CGRect(x: 40, y: 120, width: 680, height: 70))

            return context.makeImage()
        }

        // MARK: - Output

        private static func hostedImage<V: View>(
            _ view: V,
            size: CGSize,
            background: NSColor = .clear,
            settle: TimeInterval = 0
        ) -> NSImage? {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            host.wantsLayer = true
            host.layer?.backgroundColor = background.cgColor

            let window = NSWindow(
                contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = background.alphaComponent >= 1
            window.backgroundColor = background
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if settle > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(settle))
            }
            host.displayIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return nil
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            window.orderOut(nil)
            return image
        }

        private static func render<V: View>(_ view: V, scale: CGFloat = 2) -> NSImage? {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            renderer.isOpaque = false
            return renderer.nsImage
        }

        private static func write(_ image: NSImage?, name: String, to directory: URL) {
            guard let image, let data = pngData(from: image) else { return }
            try? data.write(to: directory.appendingPathComponent(name))
        }

        private static func write(_ image: CGImage?, name: String, to directory: URL) {
            guard let image, let data = pngData(from: image) else { return }
            try? data.write(to: directory.appendingPathComponent(name))
        }

        private static func pngData(from image: NSImage) -> Data? {
            guard let tiff = image.tiffRepresentation,
                let representation = NSBitmapImageRep(data: tiff)
            else { return nil }
            return representation.representation(using: .png, properties: [:])
        }

        private static func pngData(from image: CGImage) -> Data? {
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }

        private static func demoEditorImage() -> CGImage? {
            guard let image = render(DemoEditorView(), scale: 1) else { return nil }
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        private static func nsImage(from image: CGImage) -> NSImage {
            NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }

        private static func restore(_ value: Any?, forKey key: String) {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
#endif
