import CaptureCore
import CoreGraphics
import SharedKit
import SwiftUI

struct CapturePreferencesView: View {
    @AppStorage(PreferenceKeys.captureOpenEditor)
    private var openEditor = PreferenceDefaults.captureOpenEditor
    @AppStorage(PreferenceKeys.captureCopyToClipboard)
    private var copyToClipboard = PreferenceDefaults.captureCopyToClipboard
    @AppStorage(PreferenceKeys.captureIncludeCursor)
    private var includeCursor = PreferenceDefaults.captureIncludeCursor
    @AppStorage(PreferenceKeys.captureAutoOCR)
    private var autoOCR = PreferenceDefaults.captureAutoOCR
    @AppStorage(PreferenceKeys.captureCopyOCRText)
    private var copyOCRText = PreferenceDefaults.captureCopyOCRText
    @AppStorage(PreferenceKeys.captureSelectionStyle)
    private var selectionStyle = PreferenceDefaults.captureSelectionStyle
    @AppStorage(PreferenceKeys.captureOverlayMode)
    private var overlayMode = PreferenceDefaults.captureOverlayMode
    @AppStorage(PreferenceKeys.captureHighResolution)
    private var highResolution = PreferenceDefaults.captureHighResolution
    @AppStorage(PreferenceKeys.captureWindowStyling)
    private var windowStyling = PreferenceDefaults.captureWindowStyling
    @AppStorage(PreferenceKeys.captureMockupEnabled)
    private var mockupEnabled = PreferenceDefaults.captureMockupEnabled
    @AppStorage(PreferenceKeys.captureMockupPreset)
    private var mockupPreset = PreferenceDefaults.captureMockupPreset
    @AppStorage(PreferenceKeys.displayCanvasMode)
    private var displayCanvasMode = PreferenceDefaults.displayCanvasMode
    @AppStorage(PreferenceKeys.displayCanvasGap)
    private var displayCanvasGap = PreferenceDefaults.displayCanvasGap
    @AppStorage(PreferenceKeys.displayCanvasAlignment)
    private var displayCanvasAlignment = PreferenceDefaults.displayCanvasAlignment
    @AppStorage(PreferenceKeys.captureImageFormat)
    private var imageFormat = PreferenceDefaults.captureImageFormat
    @AppStorage(PreferenceKeys.captureJPEGQuality)
    private var jpegQuality = PreferenceDefaults.captureJPEGQuality
    @AppStorage(PreferenceKeys.pickerDominantColorCount)
    private var pickerDominantColorCount = PreferenceDefaults.pickerDominantColorCount
    @AppStorage(PreferenceKeys.screenshotShelfEnabled)
    private var screenshotShelfEnabled = PreferenceDefaults.screenshotShelfEnabled
    @AppStorage(PreferenceKeys.screenshotShelfCount)
    private var screenshotShelfCount = PreferenceDefaults.screenshotShelfCount
    @AppStorage(PreferenceKeys.screenshotShelfCardHeight)
    private var screenshotShelfCardHeight = PreferenceDefaults.screenshotShelfCardHeight
    @AppStorage(PreferenceKeys.screenshotShelfImageOpacity)
    private var screenshotShelfImageOpacity = PreferenceDefaults.screenshotShelfImageOpacity
    @AppStorage(PreferenceKeys.screenshotShelfAnchor)
    private var screenshotShelfAnchorRaw = PreferenceDefaults.screenshotShelfAnchor
    @AppStorage(PreferenceKeys.screenshotShelfCollapseToRail)
    private var screenshotShelfCollapseToRail = PreferenceDefaults.screenshotShelfCollapseToRail

    private var screenshotShelfAnchor: Binding<ScreenshotShelfAnchor> {
        Binding(
            get: { ScreenshotShelfAnchor(rawValue: screenshotShelfAnchorRaw) ?? .top },
            set: { screenshotShelfAnchorRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            PreferencesCardGrid {
                screenshotShelfCard
                afterCaptureCard
                appearanceCard
                displaysCard
                imageCard
            }
        }
    }

    private var screenshotShelfCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "rectangle.stack", title: "Screenshot Shelf")

            Toggle("Enable screenshot shelf", isOn: $screenshotShelfEnabled)

            Stepper(
                "Number of screenshots: \(screenshotShelfCount)",
                value: $screenshotShelfCount,
                in: 1...6
            )
            .disabled(!screenshotShelfEnabled)

            VStack(alignment: .leading) {
                LabeledContent("Card height") {
                    Text(screenshotShelfCardHeight, format: .number.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Slider(value: $screenshotShelfCardHeight, in: 64...160, step: 4)
            }
            .disabled(!screenshotShelfEnabled)

            VStack(alignment: .leading) {
                LabeledContent("Image opacity") {
                    Text(screenshotShelfImageOpacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                Slider(value: $screenshotShelfImageOpacity, in: 0.2...1, step: 0.05)
            }
            .disabled(!screenshotShelfEnabled)

            VStack(alignment: .leading, spacing: 8) {
                Text("Position")
                    .font(.subheadline.weight(.medium))
                ShelfPositionPicker(selection: screenshotShelfAnchor)
            }
            .disabled(!screenshotShelfEnabled)

            Toggle("Collapse to rail when idle", isOn: $screenshotShelfCollapseToRail)
                .disabled(!screenshotShelfEnabled)

            PreferencesCardCaption(
                text: "The rail stays visible; rest the pointer on it for a moment to expand the shelf."
            )
            PreferencesCardCaption(
                text: "The shelf hangs below the menu bar. Drag thumbnails to reorder."
            )
            PreferencesCardCaption(
                text: "Shelf items are kept only for the current session unless saved to History."
            )
        }
    }

    private var afterCaptureCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "camera.viewfinder", title: "After Capture")

            PreferencesCardCaption(
                text: """
                Area captures ask whether to copy or edit when you confirm the selection. \
                These settings apply to window, fullscreen, and scrolling captures.
                """
            )

            Toggle("Open annotation editor", isOn: $openEditor)
            TextEntryPreferencesView()
            Toggle("Copy image to clipboard", isOn: $copyToClipboard)
            Toggle("Run OCR automatically", isOn: $autoOCR)
            Toggle("Replace clipboard with recognized text", isOn: $copyOCRText)
                .disabled(!autoOCR)
                .help("When enabled, recognized text is copied automatically after capture.")
        }
    }

    private var appearanceCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "sparkles", title: "Share-ready look")

            Toggle("Add a background, padding, and shadow", isOn: $mockupEnabled)

            Picker("Template", selection: $mockupPreset) {
                ForEach(MockupPreset.allCases, id: \.self) { preset in
                    Text(LocalizedStringKey(preset.localizedKey)).tag(preset.rawValue)
                }
            }
            .pickerStyle(.menu)
            .disabled(!mockupEnabled)

            if mockupEnabled, let preset = MockupPreset(rawValue: mockupPreset) {
                MockupPreview(preset: preset)
            }

            PreferencesCardCaption(
                text: "Applies to area and fullscreen captures. Window captures keep the rounded-corner float look."
            )
        }
    }

    private var displaysCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "display.2", title: "All displays")

            Picker("Layout", selection: $displayCanvasMode) {
                Text("Horizontal").tag(DisplayCanvasMode.compactHorizontal.rawValue)
                Text("Vertical").tag(DisplayCanvasMode.compactVertical.rawValue)
                Text("Physical arrangement").tag(DisplayCanvasMode.physical.rawValue)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading) {
                LabeledContent("Gap") {
                    Text("\(Int(displayCanvasGap)) pt")
                        .monospacedDigit()
                }
                Slider(value: $displayCanvasGap, in: 0...64, step: 1)
            }
            .disabled(displayCanvasMode == DisplayCanvasMode.physical.rawValue)

            Picker("Canvas alignment", selection: $displayCanvasAlignment) {
                Text("Start").tag(DisplayCanvasAlignment.start.rawValue)
                Text("Center").tag(DisplayCanvasAlignment.center.rawValue)
                Text("End").tag(DisplayCanvasAlignment.end.rawValue)
            }
            .pickerStyle(.segmented)
            .disabled(displayCanvasMode == DisplayCanvasMode.physical.rawValue)

            PreferencesCardCaption(
                text: "Use the menu bar All Displays Capture to apply this layout."
            )
        }
    }

    private var imageCard: some View {
        PreferencesCard {
            PreferencesCardHeader(systemImage: "photo", title: "Image")

            Toggle("Include pointer", isOn: $includeCursor)
            Toggle("Native Retina resolution", isOn: $highResolution)
            Toggle("Add rounded corners and shadow", isOn: $windowStyling)

            Picker("Selection style", selection: $selectionStyle) {
                Text("Rectangle").tag(CaptureSelectionStyle.rectangle.rawValue)
                Text("Freeform").tag(CaptureSelectionStyle.freeform.rawValue)
            }
            .pickerStyle(.segmented)

            Picker("Overlay preview", selection: $overlayMode) {
                Text("Live screen").tag(CaptureOverlayMode.live.rawValue)
                Text("Static snapshot").tag(CaptureOverlayMode.snapshot.rawValue)
            }
            .pickerStyle(.segmented)

            PreferencesCardCaption(
                text: """
                    Static snapshot freezes the screen when selection starts; \
                    selection is canceled if a screen cannot be captured.
                    """
            )

            Picker("Saved image format", selection: $imageFormat) {
                Text("PNG (lossless)").tag(ImageFileFormat.png.rawValue)
                Text("JPEG (smaller)").tag(ImageFileFormat.jpeg.rawValue)
            }
            .pickerStyle(.menu)

            Picker("Number of dominant colors", selection: $pickerDominantColorCount) {
                ForEach(3...6, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.menu)

            if imageFormat == ImageFileFormat.jpeg.rawValue {
                VStack(alignment: .leading) {
                    LabeledContent("JPEG quality") {
                        Text(jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    Slider(value: $jpegQuality, in: 0.5...1, step: 0.05)
                }
            }

            PreferencesCardCaption(text: "Freeform captures always use PNG to preserve transparency.")
        }
    }
}

private struct MockupPreview: View {
    let preset: MockupPreset

    var body: some View {
        if let image = Self.render(preset) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(Text("Preview of the selected template"))
        }
    }

    private static func render(_ preset: MockupPreset) -> CGImage? {
        guard let sample = sampleImage() else { return nil }
        return MockupRenderer.render(sample, style: preset.style)
    }

    private static func sampleImage() -> CGImage? {
        let width = 360
        let height = 220
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 34, width: width, height: 34))

        let lights: [(CGFloat, CGColor)] = [
            (22, CGColor(red: 0.98, green: 0.37, blue: 0.34, alpha: 1)),
            (40, CGColor(red: 0.98, green: 0.74, blue: 0.25, alpha: 1)),
            (58, CGColor(red: 0.35, green: 0.79, blue: 0.35, alpha: 1)),
        ]
        for (offset, color) in lights {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(
                x: offset,
                y: CGFloat(height) - 24,
                width: 9,
                height: 9
            ))
        }

        context.setFillColor(CGColor(gray: 0.88, alpha: 1))
        context.fill(CGRect(x: 28, y: 122, width: 210, height: 14))
        context.setFillColor(CGColor(gray: 0.94, alpha: 1))
        context.fill(CGRect(x: 28, y: 96, width: 300, height: 10))
        context.fill(CGRect(x: 28, y: 76, width: 252, height: 10))
        context.setFillColor(CGColor(red: 0.24, green: 0.48, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 28, y: 42, width: 72, height: 18))
        return context.makeImage()
    }
}
