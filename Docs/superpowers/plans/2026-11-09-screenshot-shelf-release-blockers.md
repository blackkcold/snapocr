# Screenshot Shelf Stable-Release Blockers — Implementation Plan

> Status: proposal only. Do not change application code until the user approves this plan and execution mode.

## Goal

Resolve the verified screenshot-shelf Important findings I1, I2, and I5 in the local, unpublished v1.1.0 release candidate. Keep macOS 13+, Swift 6, existing localization conventions, and the current feature architecture. Do not include unrelated Minor findings.

## Safety and scope

- Current release candidate is local commit `ca73c9e` on `release/v1.1.0`; preserve it. Do not amend/rebase it, push, open a PR, merge, tag, or create a Release as part of this plan.
- Do not change the version number. Add a `### Fixed` subsection under the existing `[1.1.0]` changelog entry when implementing; that entry currently contains `### Added` only.
- No TCC/permission-policy changes, dependencies, Xcode project edits, or broad view-model refactors.
- GUI layout, locale propagation, live language changes, and scale wiring require manual app acceptance; unit tests cannot prove those SwiftUI/AppKit integrations.
- Do not substitute `NSScreen.backingScaleFactor` or `CaptureDisplayInfo.scaleFactor` for a measured image-pixel-to-point ratio. `PinnedImageGeometry` explicitly disallows that assumption.

## Findings and decisions

### I1 — Shelf horizontal layout

`ScreenshotShelfGeometry.panelFrame` budgets two 14 pt insets in the panel width, and the outer `VStack` padding consumes that budget. `ScreenshotShelfView` also gives the `LazyHStack` another 14 pt on both sides. The resulting scroll content is 28 pt wider than its viewport; at offset zero the final card is clipped by 14 pt and the shelf has unnecessary horizontal scroll. The geometry calculation itself is internally consistent.

**Decision:** Move the existing horizontal padding from the outer `VStack` to the header `HStack`. Keep the `LazyHStack` padding so compressed/narrow-screen layouts retain breathing room at the scroll ends. Preserve the existing 14 pt panel-to-screen margin plus 14 pt content inset (28 pt card-to-screen distance); do not redefine `horizontalInset` in this fix. The three 14 pt values in the manager/header/scroll content remain duplicated by design in this scope; do not consolidate them as an unrelated refactor.

### I2 — App language in the independent shelf panel

The shelf is hosted by an independent `NSHostingView`, outside the SwiftUI Scenes where `App.swift` injects `\.locale`. Its view literals therefore use the system language while feedback generated through `AppLocalization` uses the selected app language. In addition, `Text(card.errorMessage ?? "Preparing Screenshot Preview…")` selects `Text(String)` and treats the fallback as verbatim, so locale injection alone cannot localize it.

**Decision:** Add a defaults-injectable locale resolver to `AppLocalization`, pass that locale into `ScreenshotShelfView`, and inject it at the shelf view root. Render the placeholder as a localized string literal in its own branch. Existing shelf keys are present in en, zh-Hans, ja, and ko; avoid unnecessary resource changes. Retain the existing preference-refresh observer unless manual acceptance proves that changing language while the shelf is open does not rebuild its root view; only then add the narrowest explicit refresh path.

### I5 — Pinning from the shelf mixes pixels and points

The shelf pin path uses `CGImage` pixel dimensions as an AppKit point-sized rectangle and passes `displayScale: 1`. Both inputs must be corrected together: changing only the scale produces an incorrect zoom reading, and changing only the rectangle produces an incorrect initial size. Derive scale from image pixel width divided by the corresponding capture's point width, then use the same scale both to convert image pixels to a point-sized frame and to initialize the pinned window.

In `performCapture`, derive point width while `pinRect` and any `CaptureResult` are available: prefer `pinRect?.width` for selected regions (including `.snapshot`, which has no `CaptureResult`); otherwise use `result?.displayInfo?.frame.width` for display/window captures. Since the `.live` branch's `result` is case-scoped, retain its `displayInfo`/point width in an outer optional local before leaving the switch, then compute scale and pass it to `processCapturedImage`. If neither source provides point width, retain the existing scale-1 fallback. For scrolling capture, preserve the first window capture's `displayInfo.frame.width` before the scroll result is finalized and reset; the stitched image retains the first frame's pixel width. Do not use the preferred/backing scale factor as a substitute. A window partly outside the visible display may have a cropped pixel width that differs slightly from its full frame width; record that limit and validate with the window fully visible.

## Implementation tasks (small, testable steps)

### Task 1 — Lock shelf panel-width geometry and remove the extra inset

**Files**

- `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenshotShelfGeometryTests.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfView.swift`
- Only if an existing assertion needs adjustment: `Packages/CaptureCore/Sources/ScreenshotShelfGeometry.swift`

**Steps**

1. Add or strengthen pure geometry contract assertions for both cases: a fitting panel has width `sum(cardWidths) + spacing * (count - 1) + 2 * horizontalInset`; a constrained panel has width `visibleFrame.width - 2 * horizontalInset` (bounded at zero).
2. Run `swift test --package-path Packages/CaptureCore`. These contract assertions are expected to pass before the view change and do not detect SwiftUI padding composition; the manual layout check is the regression gate for I1.
3. Move `.padding(.horizontal, 14)` from the outer shelf `VStack` to the header `HStack`; leave the scroll-content padding and vertical padding unchanged. The geometry continues to budget a 14 pt panel margin plus 14 pt content inset.
4. Re-run the CaptureCore tests and the `EditorInteractionTests` scheme (via `bash scripts/test.sh`) to compile the changed App view. Inspect the SwiftUI view hierarchy for exactly one horizontal inset on the scrolling content; do not hand-edit generated `.xcodeproj` files. The duplicated 14 pt values remain in scope; do not consolidate constants as part of this fix.

**Verification boundary:** The pure geometry tests do not exercise SwiftUI padding composition. Confirm the actual one-card, default three-card, and constrained scrolling layouts in the manual acceptance list below.

### Task 2 — Resolve and inject the shelf's selected app locale

**Files**

- `App/SnapGlass/Sources/AppLocalization.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfView.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfManager.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfCardView.swift`
- `App/SnapGlass/Sources/App.swift` (or `App/SnapGlass/Sources/Windows/PreferencesView.swift`) only if the existing preference observer fails the live-language refresh check and an explicit app-language change callback is required
- Add `App/SnapGlass/EditorTests/AppLocalizationTests.swift` if no suitable existing test is extended.

**Steps**

1. Add tests using an isolated `UserDefaults` suite for `en`, `zh-Hans`, `ja`, and `ko`, plus missing/`system`/invalid values mapping to `Locale.current`. Assert locale identifiers; do not assert translated strings from `Bundle.main` in the test bundle.
2. Add `AppLocalization.locale(in:)` (defaulting to `.standard`) and share the language resolution with the existing bundle lookup so string and locale selection cannot drift.
3. In each `updatePanel()` root-view rebuild, resolve the current locale (do not cache it only at manager initialization), pass it from `ScreenshotShelfManager` to `ScreenshotShelfView`, and apply `.environment(\.locale, locale)` at the shelf view root. Keep `ScreenshotShelfPanel`'s concrete `NSHostingView<ScreenshotShelfView>` type.
4. Split the preview placeholder from the optional error string so the placeholder is a `LocalizedStringKey` and the dynamic error remains the supplied localized `String`.
5. Verify the existing `UserDefaults.didChangeNotification` refreshes the visible panel after an in-process language change. Add an explicit app-language change callback only if that check fails; if needed, use the macOS 13-compatible single-parameter `.onChange(of:) { newValue in }` form and do not add a second refresh mechanism pre-emptively.
6. Run the App EditorInteractionTests via the repository test script and run `bash scripts/check-localization.sh`.

### Task 3 — Carry measured image-to-point scale through shelf pinning

**Files**

- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Capture.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Processing.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Scroll.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`
- `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfManager.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+ScreenshotShelf.swift`
- `Packages/CaptureCore/Sources/PinnedImageGeometry.swift`
- `Packages/CaptureCore/Tests/CaptureCoreTests/PinnedImageGeometryTests.swift`
- `App/SnapGlass/EditorTests/ScreenshotShelfManagerTests.swift`

**Steps**

1. Add a pure geometry test for the shelf pin frame: an 800×600 px image at 2 px/pt on a 1440×900 pt screen produces a centered 400×300 pt frame; also use a screen frame with a non-zero origin. Assert the unclipped invariant `frame.width * displayScale == imagePixelWidth`. Invalid scale inputs (zero, negative, and non-finite) must fall back to 1, matching existing geometry semantics.
2. Implement a documented, testable `PinnedImageGeometry` helper that converts pixel dimensions to points using the measured display scale, fits the point-sized image to the screen, and centers it. Reuse existing `fitToScreen`/`displayScale` semantics rather than duplicating zoom math in the view model.
3. Add a `displayScale` value to each shelf card paired with an independent optional `scaleSourcePixelWidth` field; do not reuse `imagePixelSize.width`, which history synchronization can overwrite. When `captureCompleted` receives a measured scale, set `scaleSourcePixelWidth` to that same image's pixel width; when scale is omitted, leave the source width nil and use the source-compatible scale-1 fallback. Test both paths.
4. In `performCapture`, derive the point width while `pinRect` and any `CaptureResult` are available: use `pinRect?.width` first (covers region and `.snapshot` captures, which have no `CaptureResult`); otherwise read the `.live` result's `displayInfo?.frame.width` into an outer optional local before leaving the switch. Compute the measured scale there and pass it as an optional argument to `processCapturedImage`; if neither point width nor metadata exists, keep the documented scale-1 fallback.
5. For scroll capture, retain the first result's `displayInfo.frame.width` in view-model session state, clear it in `resetScrollCaptureState`, and copy it to a local before reset in `finishScrollCapture`. Derive scale from the stitched image width and that point width, then pass the scale into `processCapturedImage`. If `displayInfo` is nil, retain the scale-1 fallback and document it.
6. Put the stale-scale eligibility check in a pure/testable shelf-card or `ScreenshotShelfManager` helper (both are in the App test target); `pinScreenshotShelfItem` should only call it. Have the pin path read the stored `displayScale` and its independent `scaleSourcePixelWidth` (not `imagePixelSize.width`) from the shelf manager's card/accessor, then use the helper's point-sized centered frame and pass the same scale to `PinnedWindowManager.pin`. If a history edit/resample changes the current image width from `scaleSourcePixelWidth`, fall back to scale 1 and record that edited/resampled history images do not have an authoritative point transform; do not assume an edit transform exists.
7. Add regression tests for the pure stale-scale eligibility helper: a matching paired width uses its measured scale, while a mismatched or nil paired width takes the documented scale-1 fallback.
8. Run `swift test --package-path Packages/CaptureCore`, App EditorInteractionTests, and the full repository test script after all changes.

**Known measurement limits:** ScreenCaptureKit window captures can be clipped to visible bounds and integral pixel coordinates; the pixel/point ratio may differ slightly from the original window bounds if the window is partly off-screen. History edits can update a card's pixel dimensions after capture; compare against the independently stored `scaleSourcePixelWidth` and use the documented scale-1 fallback on mismatch. This does not guarantee physically exact sizing for edited/resampled history images; record that limitation rather than claiming an authoritative point transform. Long-window screenshots should be validated with the window fully visible. Extremely tall images that require a fit scale below the existing `minimumScale` (0.1) may clamp on first drag; record this existing limit rather than treating it as an I5 regression. The CG fallback has no point-width metadata and remains a documented scale-1 fallback rather than using backing scale.

## Manual acceptance (required before stable release)

### Shelf layout

- One card: full card visible and no scroll movement when there is no overflow.
- Default three cards: all card edges visible; no unexplained 28 pt overflow or clipped final card.
- Six cards on a narrow display: horizontal scrolling works and the first/last card retain the intended 14 pt content inset at the ends.
- Mixed image aspect ratios and multiple displays: cards remain fully visible and the shelf stays on the intended display.
- Confirm card-to-screen distance remains 28 pt (14 pt panel edge margin + 14 pt content inset); this plan preserves that existing geometry rather than redefining it.

### Localization

- With the shelf visible, switch among en, zh-Hans, ja, and ko. Verify the title, buttons, tooltips/accessibility labels, card actions, placeholder, errors, and feedback all use the selected language.
- Change language while the shelf remains open and confirm immediate refresh; separately verify system-language mode after changing the OS language/relaunching.
- Check Japanese/Korean labels for clipping in the narrow one-card layout.

### Pinning scale

- Pin region and window captures whose point-sized image remains within the existing fit-to-screen bounds on Retina and 1× displays. Verify the original point size and 100% toolbar reading when no fit-down is applied, dragging/zooming without an unexpected jump, and “restore original size”.
- For display captures, verify the toolbar reading equals the fit-to-screen ratio `fittedFrame.width / (imagePixelWidth / displayScale)`; do not require 100% when the screenshot is fitted down to the 90% visible-area limit.
- Pin a long scrolling capture made from a fully visible window on Retina and 1× displays. Verify its aspect ratio is preserved, its width is not doubled by treating pixels as points, and its toolbar reading equals the applied fit ratio `fittedFrame.width / (imagePixelWidth / displayScale)`; do not require its fitted width to equal the original window width because fitting the tall image can scale it down by height.
- Check a history-edited shelf image. If its width differs from `scaleSourcePixelWidth`, verify the documented scale-1 fallback and record the resulting limitation; do not claim exact physical sizing for that edited item. For extremely tall images that hit the existing 0.1 minimum-scale clamp, record the expected first-drag behavior separately from the I5 correction.
- Exercise mixed-DPI capture/display combinations. Record any clipping-related scale deviation and the CG fallback's scale-1 limitation; do not use the backing scale as proof of correctness.

## Completion gates

- Relevant CaptureCore and App tests pass; localization parity check passes; lint/format commands report results without hiding warnings.
- Manual acceptance above is recorded separately from automated tests. No GUI behavior is marked verified from static review or unit tests.
- After this plan and execution mode are explicitly approved, implementation and verification may proceed. Stable publication remains blocked until the separate recording plan is also completed, the combined changes are reviewed, and a new Gate 2 is approved.
