import AppKit
import CaptureCore
import SwiftUI

@preconcurrency import ScreenCaptureKit

struct RecordingSourceSelection: Sendable {
    let source: RecordingSource
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let sourceFrame: CGRect
    let displayPixelSize: CGSize
}

private struct RecordingDisplayOption: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let pixelSize: CGSize
    let screen: NSScreen?
}

private struct RecordingWindowOption: Identifiable {
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let display: RecordingDisplayOption
}

private struct RecordingSourcePickerView: View {
    let displays: [RecordingDisplayOption]
    let windows: [RecordingWindowOption]
    let onDisplay: (RecordingDisplayOption) -> Void
    let onRegion: (RecordingDisplayOption) -> Void
    let onWindow: (RecordingWindowOption) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppLocalization.string("Choose a source to record"))
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceSection("Displays") {
                        ForEach(displays) { display in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(display.name)
                                        .font(.headline)
                                    Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button(AppLocalization.string("Record Display")) {
                                    onDisplay(display)
                                }
                                .buttonStyle(.borderedProminent)
                                Button(AppLocalization.string("Select Region")) {
                                    onRegion(display)
                                }
                                .disabled(display.screen == nil)
                            }
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    sourceSection("Windows") {
                        if windows.isEmpty {
                            Text(AppLocalization.string("No available windows"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(windows) { window in
                                Button {
                                    onWindow(window)
                                } label: {
                                    HStack {
                                        Label(window.title, systemImage: "macwindow")
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(window.display.name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }

    private func sourceSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string(title))
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

@MainActor
final class RecordingSourcePickerPanel: NSPanel {
    private static var retainedPanels: [RecordingSourcePickerPanel] = []
    private static var activeRequestID: UUID?

    private let requestID: UUID
    private let displays: [RecordingDisplayOption]
    private let windows: [RecordingWindowOption]
    private let onComplete: (RecordingSourceSelection?) -> Void
    private let onFailure: (String) -> Void
    private var didFinish = false

    static func show(
        onComplete: @escaping (RecordingSourceSelection?) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        let requestID = UUID()
        activeRequestID = requestID
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true,
                    onScreenWindowsOnly: true
                )
                guard activeRequestID == requestID else { return }
                guard !content.displays.isEmpty else {
                    activeRequestID = nil
                    onFailure(AppLocalization.string("No displays are available to record."))
                    onComplete(nil)
                    return
                }
                let panel = RecordingSourcePickerPanel(
                    content: content,
                    requestID: requestID,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
                retainedPanels.append(panel)
                panel.orderFrontRegardless()
                panel.makeKey()
            } catch {
                guard activeRequestID == requestID else { return }
                activeRequestID = nil
                onFailure(AppLocalization.string("Could not load recording sources: %@", error.localizedDescription))
                onComplete(nil)
            }
        }
    }

    @MainActor
    static func cancelActivePanel() {
        activeRequestID = nil
        let panels = retainedPanels
        for panel in panels {
            panel.finish(with: nil)
        }
    }

    private init(
        content: SCShareableContent,
        requestID: UUID,
        onComplete: @escaping (RecordingSourceSelection?) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        self.requestID = requestID
        let screensByID: [CGDirectDisplayID: NSScreen] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { return nil }
            return (displayID, screen)
            }
        )
        let displayOptions = content.displays.map { display in
            RecordingDisplayOption(
                id: display.displayID,
                name: screensByID[display.displayID]?.localizedName
                    ?? AppLocalization.string("Display %d", Int(display.displayID)),
                frame: display.frame,
                pixelSize: CGSize(width: display.width, height: display.height),
                screen: screensByID[display.displayID]
            )
        }
        displays = displayOptions
        let appBundleIdentifier = Bundle.main.bundleIdentifier
        windows = content.windows.compactMap { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.owningApplication?.bundleIdentifier != appBundleIdentifier,
                  let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let display = displayOptions.first(where: { $0.frame.contains(window.frame) }) else {
                return nil
            }
            return RecordingWindowOption(
                id: window.windowID,
                title: title,
                frame: window.frame,
                display: display
            )
        }
        self.onComplete = onComplete
        self.onFailure = onFailure

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let size = NSSize(width: 720, height: 520)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = AppLocalization.string("Record Screen")
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(
            rootView: RecordingSourcePickerView(
                displays: displays,
                windows: windows,
                onDisplay: { [weak self] in self?.selectDisplay($0) },
                onRegion: { [weak self] in self?.selectRegion($0) },
                onWindow: { [weak self] in self?.selectWindow($0) },
                onCancel: { [weak self] in self?.finish(with: nil) }
            )
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        finish(with: nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finish(with: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private func selectDisplay(_ display: RecordingDisplayOption) {
        finish(with: RecordingSourceSelection(
            source: .display(displayID: display.id),
            displayID: display.id,
            displayFrame: display.frame,
            sourceFrame: display.frame,
            displayPixelSize: display.pixelSize
        ))
    }

    private func selectWindow(_ window: RecordingWindowOption) {
        finish(with: RecordingSourceSelection(
            source: .window(windowID: window.id),
            displayID: window.display.id,
            displayFrame: window.display.frame,
            sourceFrame: window.frame,
            displayPixelSize: window.display.pixelSize
        ))
    }

    private func selectRegion(_ display: RecordingDisplayOption) {
        guard let screen = display.screen else {
            onFailure(AppLocalization.string("The selected display is no longer available."))
            finish(with: nil)
            return
        }
        guard !didFinish else { return }
        didFinish = true
        if Self.activeRequestID == requestID {
            Self.activeRequestID = nil
        }
        Self.retainedPanels.removeAll { $0 === self }
        let completion = onComplete
        super.close()

        AreaSelectionPanel.show(
            style: .rectangle,
            purpose: .recordingRegion,
            on: screen
        ) { result in
            guard case .recordingRegion(let region) = result,
                  region.displayID == display.id,
                  let source = RecordingSource.makeRegion(
                    displayID: region.displayID,
                    quartzRect: region.quartzRect,
                    displayFrame: CGDisplayBounds(region.displayID)
                  ) else {
                completion(nil)
                return
            }
            completion(RecordingSourceSelection(
                source: source,
                displayID: display.id,
                displayFrame: display.frame,
                sourceFrame: region.quartzRect,
                displayPixelSize: display.pixelSize
            ))
        }
    }

    private func finish(with selection: RecordingSourceSelection?) {
        guard !didFinish else { return }
        didFinish = true
        if Self.activeRequestID == requestID {
            Self.activeRequestID = nil
        }
        Self.retainedPanels.removeAll { $0 === self }
        super.close()
        onComplete(selection)
    }
}
