import AppKit
import CaptureCore
import Testing

@MainActor
struct PinnedImageViewResizeTests {
    @Test func leftMouseButtonDetectorChecksThePrimaryButtonBit() {
        #expect(PinnedImageView.leftMouseButtonIsPressed(buttonMask: 1))
        #expect(!PinnedImageView.leftMouseButtonIsPressed(buttonMask: 0))
        #expect(!PinnedImageView.leftMouseButtonIsPressed(buttonMask: 2))
    }

    @Test func resizeExitUpdatesHoverBeforeReportingResizeEnd() throws {
        let (window, view) = try makePinnedImageView()
        defer { window.close() }

        var callbacks: [String] = []
        view.onHoverChanged = { callbacks.append("hover:\($0)") }
        view.onResizeChanged = { callbacks.append("resize:\($0)") }

        let corner = CGPoint(x: 199, y: 1)
        view.mouseEntered(with: try mouseEvent(.mouseMoved, at: corner, in: window))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner, in: window))
        callbacks.removeAll()

        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: -20, y: -20), in: window))

        #expect(callbacks == ["hover:false", "resize:false"])
    }

    @Test func scrollWheelCannotReplaceCornerResizeFrameWrites() throws {
        let (window, view) = try makePinnedImageView(isLeftMouseButtonPressed: { true })
        defer { window.close() }

        let startFrame = window.frame
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 199, y: 1), in: window))

        let cgEvent = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0)
        )
        let scrollEvent = try #require(NSEvent(cgEvent: cgEvent))
        view.scrollWheel(with: scrollEvent)

        #expect(window.frame == startFrame)
    }

    @Test func hoverExitIsDeferredUntilCornerResizeEnds() throws {
        let (window, view) = try makePinnedImageView(isLeftMouseButtonPressed: { true })
        defer { window.close() }

        var hoverChanges: [Bool] = []
        view.onHoverChanged = { hoverChanges.append($0) }
        let corner = CGPoint(x: 199, y: 1)
        let pointerEvent = try mouseEvent(.mouseMoved, at: corner, in: window)
        view.mouseEntered(with: pointerEvent)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner, in: window))

        view.mouseExited(with: pointerEvent)
        #expect(hoverChanges == [true])

        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: -20, y: -20), in: window))
        #expect(hoverChanges == [true, false])
    }

    @Test func lostMouseUpIsRecoveredOnNextMouseMovement() throws {
        var isLeftMouseButtonPressed = true
        let (window, view) = try makePinnedImageView {
            isLeftMouseButtonPressed
        }
        defer { window.close() }

        var resizeChanges: [Bool] = []
        view.onResizeChanged = { resizeChanges.append($0) }
        let corner = CGPoint(x: 199, y: 1)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner, in: window))
        isLeftMouseButtonPressed = false

        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: CGPoint(x: 100, y: 50), in: window))

        #expect(resizeChanges == [true, false])
    }

    @Test func lostMouseUpIsRecoveredByScrollWheelWithoutPointerMovement() throws {
        var isLeftMouseButtonPressed = true
        let (window, view) = try makePinnedImageView {
            isLeftMouseButtonPressed
        }
        defer { window.close() }

        var resizeChanges: [Bool] = []
        view.onResizeChanged = { resizeChanges.append($0) }
        let startFrame = window.frame
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 199, y: 1), in: window))
        isLeftMouseButtonPressed = false

        let cgEvent = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0)
        )
        view.scrollWheel(with: try #require(NSEvent(cgEvent: cgEvent)))

        #expect(resizeChanges == [true, false])
        #expect(window.frame != startFrame)
    }

    @Test func releasedMouseDraggedEventEndsResizeWithoutWritingFrame() throws {
        var isLeftMouseButtonPressed = true
        let (window, view) = try makePinnedImageView {
            isLeftMouseButtonPressed
        }
        defer { window.close() }

        var resizeChanges: [Bool] = []
        var scaleChanges: [CGFloat] = []
        view.onResizeChanged = { resizeChanges.append($0) }
        view.onScaleChanged = { scaleChanges.append($0) }
        let startFrame = window.frame
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 199, y: 1), in: window))
        isLeftMouseButtonPressed = false

        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: CGPoint(x: 180, y: 20), in: window))

        #expect(resizeChanges == [true, false])
        #expect(scaleChanges.isEmpty)
        #expect(window.frame == startFrame)
    }

    @Test func secondCornerMouseDownContinuesResizeWithoutEndBeginCallbacks() throws {
        let (window, view) = try makePinnedImageView()
        defer { window.close() }

        var resizeChanges: [Bool] = []
        view.onResizeChanged = { resizeChanges.append($0) }
        let corner = CGPoint(x: 199, y: 1)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner, in: window))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner, in: window))

        #expect(resizeChanges == [true])

        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: corner, in: window))
        #expect(resizeChanges == [true, false])
    }

    @Test func cursorUpdateRestoresActiveResizeCursor() throws {
        let (window, view) = try makePinnedImageView()
        defer { window.close() }

        let corner = CGPoint(x: 199, y: 1)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner, in: window))
        let resizeCursor = NSCursor.current
        #expect(resizeCursor !== NSCursor.arrow)

        NSCursor.arrow.set()
        view.cursorUpdate(with: try mouseEvent(.mouseMoved, at: corner, in: window))

        #expect(NSCursor.current === resizeCursor)

        NSCursor.arrow.set()
        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: corner, in: window))

        #expect(NSCursor.current === resizeCursor)
    }

    @Test func mouseMovementCannotClearCornerHighlightDuringResize() throws {
        let (window, view) = try makePinnedImageView(isLeftMouseButtonPressed: { true })
        defer { window.close() }

        let corner = CGPoint(x: 199, y: 1)
        view.mouseEntered(with: try mouseEvent(.mouseMoved, at: corner, in: window))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: corner, in: window))
        let beforeDrag = try renderedPixels(of: view)

        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: CGPoint(x: 100, y: 50), in: window))

        #expect(try renderedPixels(of: view) == beforeDrag)
    }

    @Test func trackingAreaIsNotRecreatedDuringCornerResize() throws {
        let (window, view) = try makePinnedImageView(isLeftMouseButtonPressed: { true })
        defer { window.close() }

        view.updateTrackingAreas()
        let initialArea = try #require(view.trackingAreas.first)
        #expect(initialArea.options.contains(.inVisibleRect))
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 199, y: 1), in: window))

        view.updateTrackingAreas()

        let activeResizeArea = try #require(view.trackingAreas.first)
        #expect(activeResizeArea === initialArea)
    }

    private func makePinnedImageView(
        isLeftMouseButtonPressed: @escaping () -> Bool = { true }
    ) throws -> (NSWindow, PinnedImageView) {
        let context = try #require(
            CGContext(
                data: nil,
                width: 100,
                height: 50,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        let image = try #require(context.makeImage())
        let view = PinnedImageView(
            image: image,
            displayScale: 1,
            onRequestClose: {},
            onCopyImage: {},
            onCopyOCRText: {},
            onCloseAll: {},
            isLeftMouseButtonPressed: isLeftMouseButtonPressed
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (window, view)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    private func renderedPixels(of view: PinnedImageView) throws -> [UInt8] {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 200,
                pixelsHigh: 100,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        let pixels = try #require(bitmap.bitmapData)
        return Array(UnsafeBufferPointer(start: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }
}
