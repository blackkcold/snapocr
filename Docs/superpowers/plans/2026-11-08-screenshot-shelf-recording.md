# SnapGlass Screenshot Shelf and Native Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. This work stays in the current session; do not dispatch subagents.

**Goal:** Add a session-only recent-screenshot shelf and reliable native screen recording to SnapGlass without changing its minimum OS version or adding external dependencies.

**Architecture:** Keep screenshot presentation, capture coordination, recording controls, and preferences in the App target. Put deterministic shelf policy/geometry, session asset storage, recording configuration, writer lifecycle, and file publication in `CaptureCore`, matching its existing pure-logic tests and ScreenCaptureKit adapter. Keep screenshot history as the source of truth for saved images; use an ephemeral encrypted session cache only for unsaved captures.

**Tech Stack:** Swift 6, macOS 13+, SwiftUI/AppKit, ScreenCaptureKit, AVFoundation/AVAssetWriter, CryptoKit, existing SharedKit/CaptureCore/HistoryCore packages, XcodeGen.

**Spec:** User-provided “SnapGlass 新功能完整方案 v1.0” in the first user message of this session (the approved Stage A and Stage B scope; no separate spec file exists in the repository).

## Global Constraints

- Keep macOS 13 as the minimum deployment target.
- Use one recording path: ScreenCaptureKit → media buffers → AVAssetWriter → MP4.
- Add no FFmpeg or other external recording dependency and make no dependency or lockfile changes.
- Screenshot shelf defaults: enabled, 3 cards, approximately 160×96 pt, image opacity 90%; count range 1–6, card-height range 64–160 pt, image-opacity range 20%–100%.
- Keep screenshot order by capture-completion sequence, newest first; asynchronous OCR/history completion must not reorder entries.
- Bound shelf thumbnail cache to approximately 16 MiB and encrypted session-original storage to 512 MiB; use a per-session in-memory-only encryption key and remove stale session assets at next launch.
- Recording defaults: Movies/SnapGlass/Recordings, MP4/H.264, 1080p-class maximum, 30 fps, 8 Mbps; system audio off by default. Default audio format when enabled: AAC, 48 kHz, 128 kbps.
- Recording free-space policy starts at approximately 1 GiB available, checks at low frequency (about 2 seconds), and attempts to stop/finalize before space falls below approximately 512 MiB.
- Recording output is written to a unique temporary file inside the chosen destination and published only after AVAssetWriter finalization succeeds. Never overwrite an existing recording or claim success before publication.
- Do not implement Stage C or other explicit non-goals: pause/resume, microphone, HDR, editing, GIF, multi-display stitching, post-record compression, video history, or drag-out from the shelf.
- Translate all new user-facing strings in the existing English, Simplified Chinese, Japanese, and Korean `.strings` files.
- Do not hand-edit generated `.xcodeproj` files. Do not commit changes.
- Follow `Docs/AGENTS.md`: update `CHANGELOG.md`, add DocC comments to new public APIs, run the affected Package tests, `swift-format`, `swiftlint`, and `bash scripts/check-localization.sh`.
- Do not modify existing package protocols, permission behavior, CI configuration, or package dependencies without asking first. Prefer the existing ScreenCaptureKit permission flow; if recording requires a permission-policy change, pause and ask before changing it.
- Network access is limited to fetching the already-locked KeyboardShortcuts 2.4.0 dependency if a test/build proves it is required; otherwise make no network requests.

## Review Focus

1. Delayed OCR/history work must not reorder or resurrect shelf entries; `ScreenshotShelfStateTests` pins sequence ordering, link updates, removal, and limit changes.
2. History autosave disabled, asset write failure, and cache-budget pressure must not break the original capture or present a thumbnail as the original; `ScreenshotShelfSessionStoreTests` pins budget, encrypted round-trip, and eviction behavior.
3. History deletion, cleanup eviction, and overwrite must remove or refresh linked shelf assets without changing the capture identity/order; HistoryCore notification tests and shelf-state tests cover the contract.
4. A recording source disappearing, changing dimensions, losing permission, or crossing display bounds must stop/fail explicitly rather than silently record the wrong content; recording configuration/state tests cover deterministic policy, with device checks in the final acceptance pass.
5. Writer backpressure, audio/video timestamp alignment, and finish/rename failures must not produce a false “saved” state or destroy a recoverable partial; writer-state and output-transaction tests cover failure transitions and preservation.

---

### Task 1: Deterministic screenshot-shelf policy, geometry, and session assets

**Files:**
- Create: `Packages/CaptureCore/Sources/ScreenshotShelfState.swift`
- Create: `Packages/CaptureCore/Sources/ScreenshotShelfGeometry.swift`
- Create: `Packages/CaptureCore/Sources/ScreenshotShelfSessionStore.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenshotShelfStateTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenshotShelfGeometryTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/ScreenshotShelfSessionStoreTests.swift`

**Interfaces:**
- `ScreenshotShelfState` owns only ordered capture metadata, never image bytes. It exposes `init(limit: Int = 3)`, `insert(captureID: UUID, completionSequence: UInt64) -> [UUID]`, `setLimit(_:) -> [UUID]`, `linkHistory(captureID: UUID, historyID: UUID)`, `remove(captureID: UUID)`, and `clear() -> [UUID]`. `entries` is newest-first; the effective limit is clamped to 1...6; returned IDs identify entries whose assets may be released.
- `ScreenshotShelfGeometry.panelFrame(visibleFrame: CGRect, cardWidths: [CGFloat], cardHeight: CGFloat, spacing: CGFloat, horizontalInset: CGFloat, topInset: CGFloat, verticalInset: CGFloat) -> CGRect` returns a top-centered viewport bounded by the supplied safe visible frame. Per-image widths preserve aspect ratio; the viewport may become horizontally scrollable without reducing card dimensions.
- `ScreenshotShelfSessionStore` is an actor that accepts encoded original/thumbnail `Data`, encrypts originals with a randomly generated per-instance AES-GCM key, keeps thumbnail data in a bounded cache, and writes originals only under its feature-owned session directory. Its operations are `store(originalData:thumbnailData:captureID:)`, `originalData(for:)`, `thumbnailData(for:)`, `remove(captureID:)`, and `clear()`; expose byte-budget injection internally for deterministic tests.

- [ ] **Step 1: Add failing policy and geometry tests**

  `ScreenshotShelfStateTests` must assert: inserting completion sequences 1, 2, 3, 4 with limit 3 yields IDs in order 4, 3, 2 and returns 1 as evicted; linking a history ID leaves order unchanged; lowering the limit evicts oldest entries immediately; raising it does not restore removed IDs; remove/clear do not affect unrelated IDs. `ScreenshotShelfGeometryTests` must assert top-centering, visible-frame bounds, and horizontal overflow without card-height reduction on a narrow screen.

- [ ] **Step 2: Run the focused CaptureCore tests and confirm they fail**

  Run: `swift test --package-path Packages/CaptureCore --filter ScreenshotShelf`
  Expected: FAIL because the new policy/geometry types do not exist.

- [ ] **Step 3: Implement the smallest pure policy and geometry types**

  Keep stable identity separate from completion order and history linkage. Clamp configuration at the state boundary, not only in UI controls.

- [ ] **Step 4: Run the focused tests and confirm they pass**

  Run: `swift test --package-path Packages/CaptureCore --filter ScreenshotShelf`
  Expected: all shelf state and geometry tests pass.

- [ ] **Step 5: Add failing session-store tests**

  `ScreenshotShelfSessionStoreTests` must assert encrypted originals round-trip within the same store instance, ciphertext does not contain the original plaintext, thumbnail/original budgets are enforced, the oldest eligible entry is evicted before a new asset is refused, and a refused asset produces an explicit error without deleting unrelated assets.

- [ ] **Step 6: Run the session-store tests and confirm they fail, then implement the store**

  Run before implementation: `swift test --package-path Packages/CaptureCore --filter ScreenshotShelfSessionStoreTests` (expected FAIL).
  Implement per-session AES-GCM encryption with an in-memory-only key, bounded thumbnail/original storage, feature-directory scoping, and stale-session cleanup. Do not silently fall back to thumbnail bytes for original-image operations.

- [ ] **Step 7: Run all focused tests and confirm they pass**

  Run: `swift test --package-path Packages/CaptureCore --filter ScreenshotShelf`
  Expected: policy, geometry, and session-store tests pass.

---

### Task 2: Screenshot-shelf UI, capture integration, and history synchronization

**Files:**
- Create: `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfManager.swift`
- Create: `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfPanel.swift`
- Create: `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfView.swift`
- Create: `App/SnapGlass/Sources/ScreenshotShelf/ScreenshotShelfCardView.swift`
- Create: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+ScreenshotShelf.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Processing.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Capture.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Scroll.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarView.swift`
- Modify: `App/SnapGlass/Sources/App.swift`
- Modify: `App/SnapGlass/Sources/Windows/CapturePreferencesView.swift`
- Modify: `App/SnapGlass/Sources/Windows/PreferencesView.swift` (add shelf/recording shortcut rows to the existing Shortcuts section)
- Modify: `Packages/SharedKit/Sources/PreferenceKeys.swift`
- Modify: `Packages/SharedKit/Sources/HotKeys/HotKeyManager.swift`
- Modify: `Packages/HistoryCore/Sources/HistoryActor+HistoryProtocol.swift`
- Modify: `App/SnapGlass/Resources/en.lproj/Localizable.strings`
- Modify: `App/SnapGlass/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `App/SnapGlass/Resources/ja.lproj/Localizable.strings`
- Modify: `App/SnapGlass/Resources/ko.lproj/Localizable.strings`
- Test: `Packages/HistoryCore/Tests/HistoryCoreTests/HistoryChangeNotificationTests.swift`

**Interfaces:**
- `ScreenshotShelfManager` owns the AppKit panel, `ScreenshotShelfState`, the session store, card presentation state, and history-change observation. It assigns a `captureID` synchronously at capture completion, then stores the original/thumbnail asynchronously; cache failure is surfaced in the card/toast and never fails the original screenshot flow.
- `CaptureViewModel+ScreenshotShelf` exposes menu/shortcut actions `toggleScreenshotShelf()`, `showScreenshotShelf()`, `hideScreenshotShelf()`, `removeScreenshotShelfItem(captureID:)`, and `clearScreenshotShelf()`.
- `CaptureViewModel+Processing.processCapturedImage(...)` records one shelf entry at the successful-capture boundary before OCR/history work. When history save completes, the returned history ID is linked to that existing capture ID. A later original-image overwrite refreshes the same card; edits, copy, and pin operations do not create new shelf entries.
- Add preference keys/defaults for enabled (true), count (3), card height (96 pt), and image opacity (0.9). Any stored value is clamped to count 1...6, height 64...160, and opacity 0.2...1.

- [ ] **Step 1: Add failing history-change notification tests**

  Extend HistoryCore tests to assert `HistoryActor.imagesDidChange` is posted after committed delete and clear operations. Save and overwrite already post this notification; do not change those semantics.

- [ ] **Step 2: Run the focused HistoryCore tests and confirm the deletion/clear cases fail**

  Run: `swift test --package-path Packages/HistoryCore --filter History`
  Expected: new delete/clear notification assertions fail before implementation.

- [ ] **Step 3: Post the existing image-change notification after successful delete/clear**

  Post only after the HistoryActor transaction commits. Count/age/disk cleanup already delegates whole-entry removal through `delete(id:)`, so it must not add a second notification path.

- [ ] **Step 4: Run focused HistoryCore tests and confirm they pass**

  Run: `swift test --package-path Packages/HistoryCore --filter History`
  Expected: notification tests and existing history tests pass.

- [ ] **Step 5: Add shelf preference, shortcut, card-action, and capture-flow checks**

  Verify persisted defaults and clamps; capture completion sequence is registered before OCR/history awaits; out-of-order history callbacks only link IDs; recording/screenshot suppression can restore prior manual visibility; removing/clearing a shelf item never calls HistoryActor delete/clear. Use the existing app test scheme if these pure cases can be added without pulling AppKit window setup into tests; otherwise keep them as explicit manual acceptance checks.

- [ ] **Step 6: Implement the one-panel shelf and integration**

  Build one nonactivating floating panel, top-centered on the source display below the menu bar/notch, with proportional full-image cards and horizontal scrolling. Card actions use the original image for edit/copy/pin, report feedback in-card, and remove only the shelf entry. Pin placement uses the selected target screen's fitted geometry, not fabricated source-selection coordinates.

  Preserve show intent separately from temporary suppression: new successful capture may show the shelf; manual hide persists until explicit show or a later capture; full-screen/lock/recording suppression does not delete entries; lock does not re-expose the shelf on unlock; empty shelf stays hidden; recording prohibits showing it. Hide the shelf's owned windows before app-controlled display capture and restore only the prior eligible state; do not rely on `sharingType = .none` alone.

  Saved entries read original bytes from HistoryCore on demand; unsaved entries use the encrypted session store. The shelf must work when history autosave is off. Link overwrite refreshes without changing identity/order; history delete/clear/eviction removes linked cards and session assets. Keep only display-sized thumbnails resident, cap thumbnail cache at 16 MiB, cap encrypted originals at 512 MiB, and bound in-flight cache work.

- [ ] **Step 7: Run app/package tests and review Stage A behavior**

  Run: `swift test --package-path Packages/CaptureCore` and `swift test --package-path Packages/HistoryCore`, then the app test schemes through `bash scripts/test.sh` after the implementation is buildable.
  Expected: tests pass; manual checks cover default 3-card display, settings changes, horizontal overflow, no-history-save operation, card actions, ordering under delayed history, history deletion/overwrite, manual hide, full-screen/lock suppression, and self-capture exclusion.

---

### Task 3: Recording configuration, source geometry, writer lifecycle, and safe output transaction

**Files:**
- Create: `Packages/CaptureCore/Sources/RecordingConfiguration.swift`
- Create: `Packages/CaptureCore/Sources/RecordingSessionState.swift`
- Create: `Packages/CaptureCore/Sources/RecordingOutputTransaction.swift`
- Create: `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingConfigurationTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingSessionStateTests.swift`
- Test: `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingOutputTransactionTests.swift`

**Interfaces:**
- `RecordingConfiguration` is an immutable per-session snapshot containing codec, resolution limit, frame-rate cap, average video bitrate, and system-audio enablement. It exposes validation against available encoder/format capabilities and a pure output-dimension calculation that never upsizes or distorts aspect ratio.
- `RecordingSource` represents exactly one display, one window, or one rectangle constrained to one display. Region conversion from Quartz global coordinates to the selected display's local source rectangle is pure and tested.
- `RecordingOutputTransaction` chooses a unique `SnapGlass_YYYY-MM-DD_HH-mm-ss.mp4` name with a numeric collision suffix, creates a hidden same-directory partial file, and publishes only after a successful writer finish. A publish failure returns/retains the partial URL; it never overwrites or deletes a valuable partial automatically.
- `ScreenRecordingEngine` owns one ScreenCaptureKit stream and one AVAssetWriter lifecycle. It consumes bounded sample-buffer work on a dedicated queue, starts the writer timeline at the first accepted video sample, appends audio on the same time basis when enabled, preserves source timestamps when dropping video under backpressure, and exposes an awaited stop/finalize result.

- [ ] **Step 1: Add failing configuration, geometry, state, and transaction tests**

  `RecordingConfigurationTests` must assert the default is 1080p-class/30 fps/H.264/8 Mbps with audio off; output dimensions cap at the selected bounds without upscaling/distortion; unsupported codec/format combinations are rejected; bitrate recommendations vary with codec, pixel count, and FPS. Region tests must reject cross-display/out-of-bounds rectangles. `RecordingSessionStateTests` must reject duplicate start/stop transitions. `RecordingOutputTransactionTests` must assert same-directory partial creation, collision suffixing without overwrite, publication only after finish, and retained partial on publication failure.

- [ ] **Step 2: Run the focused CaptureCore recording tests and confirm they fail**

  Run: `swift test --package-path Packages/CaptureCore --filter Recording`
  Expected: FAIL because recording policy/transaction types do not yet exist.

- [ ] **Step 3: Implement pure recording configuration, state, and output transaction**

  Probe `AVAssetWriter`/encoder settings during validation. Keep 1080p as the default ceiling, not the maximum capability; custom source resolution remains opt-in. Do not add a software-encoding fallback that silently increases CPU load.

- [ ] **Step 4: Run focused tests and confirm pure recording logic passes**

  Run: `swift test --package-path Packages/CaptureCore --filter Recording`
  Expected: configuration, region, state, and output transaction tests pass.

- [ ] **Step 5: Add the ScreenCaptureKit/AVAssetWriter engine and testable failure seams**

  Support display/window/region filters, H.264/HEVC validation, requested frame interval and scaling, optional system audio at AAC 48 kHz/128 kbps, and explicit exclusion of SnapGlass shelf/HUD window IDs only (never exclude the whole process). Use a bounded queue and no per-frame Task creation. Handle sample-buffer readiness, timestamps, first-frame startup, stop/drain/finalize, source loss, writer failure, and retained partial output as explicit state transitions.

- [ ] **Step 6: Run focused and full CaptureCore tests/build**

  Run: `swift test --package-path Packages/CaptureCore --filter Recording`, then `swift test --package-path Packages/CaptureCore`.
  Expected: all pure recording tests pass and the Core target builds. Hardware-only source/audio capture remains for the final acceptance pass.

---

### Task 4: Recording source picker, HUD, settings, and App lifecycle integration

**Files:**
- Create: `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- Create: `App/SnapGlass/Sources/Recording/RecordingSourcePickerPanel.swift`
- Create: `App/SnapGlass/Sources/Recording/RecordingControlPanel.swift`
- Create: `App/SnapGlass/Sources/Windows/RecordingPreferencesView.swift`
- Create: `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/CaptureViewModel.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/MenuBarView.swift`
- Modify: `App/SnapGlass/Sources/Overlays/AreaSelectionPanel.swift`
- Modify: `App/SnapGlass/Sources/Overlays/AreaSelectionTypes.swift`
- Modify: `App/SnapGlass/Sources/Windows/PreferencesNavigation.swift`
- Modify: `App/SnapGlass/Sources/Windows/PreferencesView.swift`
- Modify: `Packages/SharedKit/Sources/PreferenceKeys.swift`
- Modify: `Packages/SharedKit/Sources/HotKeys/HotKeyManager.swift`
- Modify: `App/SnapGlass/Sources/App.swift`
- Modify: `App/SnapGlass/Sources/MenuBar/UpdateInstallHandoff.swift` only if required to gate termination while recording
- Modify: all four existing `Localizable.strings` files

**Interfaces:**
- `RecordingSessionController` snapshots preferences/source into `RecordingConfiguration`, owns picker/countdown/recording/saving states, and serializes start/stop so repeated clicks cannot start duplicate streams.
- `CaptureViewModel+Recording` exposes `startRecording()`, `stopRecordingAndSave()`, and the published recording state consumed by `MenuBarView` and the HUD.
- `RecordingPreferencesView` persists the next-session configuration and directory only; changes never mutate an active recording. Default directory is obtained from `FileManager`'s Movies directory and appended with `SnapGlass/Recordings`.
- Extend area-selection presentation with an explicit recording-region purpose and a rectangular, one-display-only completion result; existing screenshot selection actions and behavior remain unchanged.

- [ ] **Step 1: Add/extend tests for setting clamps and source-state transitions**

  Test defaults, custom directory remembrance/reset without moving existing files, active-session configuration immutability, duplicate start/stop rejection, area cancellation, and one-display region bounds in the pure types from Task 3. Add an app test only if it can run without foreground interaction.

- [ ] **Step 2: Run the focused tests and confirm new assertions fail**

  Run: `swift test --package-path Packages/CaptureCore --filter Recording`
  Expected: newly added setting/state assertions fail before wiring the app controller.

- [ ] **Step 3: Implement the source picker, region flow, HUD, settings, and lifecycle**

  Offer one display, one window, or one rectangular region; include a cancellable 3-second countdown and a stop-and-save control. Keep the HUD and countdown windows out of display recordings by window ID; exclude only SnapGlass control windows, not user-visible SnapGlass content. Keep shelf and recording mutually exclusive with screenshot/scroll-capture starts. Show “saving” until writer finalization and file publication complete.

  Add the Recording preferences section with source-independent codec/profile/resolution/FPS/average-bitrate/audio controls, estimated size, folder selection/open/reset, and available-space status. Selecting settings must not create the destination directory. On recording start, create/check it, require about 1 GiB free, and recheck about every 2 seconds; if capacity falls below about 512 MiB, stop/finalize best-effort and report the actual outcome.

  On lock/sleep, display removal, permission loss, or an incompatible window-size/display change, stop and finalize best-effort with a specific message. Route Quit through a stop-and-save confirmation while recording. A missing custom destination requires reselection; do not silently fall back to Movies or another folder.

- [ ] **Step 4: Verify App build and focused tests**

  Run: `swift test --package-path Packages/CaptureCore --filter Recording` and build the `SnapGlass` Xcode target after regenerating the project from `project.yml` if needed.
  Expected: tests pass and App compiles with no new Swift errors. Manually exercise picker cancel, each source kind, countdown cancel, repeat start/stop, audio off/on, folder choose/reset, and completion/failure feedback.

---

### Task 5: Cross-feature verification and final review

**Files:**
- Review all changed Swift, test, preference, history, and localization files; do not add unrelated refactors.
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run the complete existing test script**

  Run: `bash scripts/test.sh`
  Expected: all eight Swift package test groups and all configured App test schemes pass. Record any pre-existing warnings separately; do not mask failures.

- [ ] **Step 2: Build the macOS App target and validate localizations**

  Run: `xcodebuild build -project SnapGlass.xcodeproj -scheme SnapGlass -destination 'platform=macOS'` (regenerate with `xcodegen generate` first only when the project is absent/stale).
  Run: `bash scripts/check-localization.sh`, `swift-format lint -p App/SnapGlass/Sources --configuration .swift-format`, `swift-format lint -p Packages/CaptureCore/Sources --configuration .swift-format`, `swift-format lint -p Packages/HistoryCore/Sources --configuration .swift-format`, and `swiftlint lint --config .swiftlint.yml`.
  Check: new localization keys are present in English, Simplified Chinese, Japanese, and Korean; new public APIs have DocC comments; `CHANGELOG.md` describes only this feature; no generated project or lockfile diff is retained unless it is an intentional source change.

- [ ] **Step 3: Review the final diff and run the manual acceptance matrix**

  Check shelf ordering, limit changes, no-history-save use, self-capture avoidance, edit overwrite/deletion, cache-full behavior, display/DPI/full-screen/lock behavior, and card actions. Check recording display/window/region selection, static 30-second and 5-minute captures, audio synchronization, HUD exclusion, naming/collision behavior, custom/default location, disk-full/drive-loss/rename failure, source change, lock/sleep, and repeated start/stop.

  Verify no Stage C feature, external dependency, silent encoder fallback, or hidden output-location fallback slipped in. Confirm no test failure is hidden and no changes are committed. If GUI/hardware recording cannot be performed in this environment, report it as unverified rather than claiming it passed.

---

## Plan Self-Review

- **Coverage:** Stage A includes policy, layout, storage/encryption, settings, visible actions, lifecycle suppression, self-capture prevention, history link/update/delete, and cache limits. Stage B includes all three single-source modes, encoding settings, system audio, destination choice, safe file publication, error handling, mutually exclusive capture state, and required lock/sleep/source-loss handling. Explicit Stage C exclusions are kept out.
- **Step scan:** Every implementation task starts with a focused failing test, implements the smallest owning component, and names an exact verification command. AppKit/ScreenCaptureKit hardware paths are called out separately for manual acceptance.
- **Type consistency:** Shelf identity/order is keyed by `captureID`; history linkage uses `historyID`; recording is a single immutable configuration/source snapshot per session; the output transaction owns partial and final URLs.
- **Review focus:** The five high-risk input classes above each have a deterministic test owner plus explicit end-to-end checks where hardware/system behavior is required.
- **Proportion:** This plan is shorter than the v1.0 specification and records only implementation boundaries, fixed defaults, tests, and review gates.
