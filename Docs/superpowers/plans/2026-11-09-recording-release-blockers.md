# Native Recording Stable-Release Blockers — Implementation Plan

> Status: revised proposal; do not change application code until the user approves this updated plan. The user has selected the C1 atomic-only contract, declined a final-MP4 `0600` requirement, and authorized I4 using the existing shared permission guide with copy that covers both screenshot capture and recording.

## Goal

Resolve C1 and I3–I7 in the local, unpublished v1.1.0 release candidate while preserving macOS 13+ support, Swift 6 concurrency constraints, and TCC policy. The user selected atomic-only publication for C1 and confirmed no final-MP4 `0600` requirement. For I4, reuse the single existing permission guide and update its shared copy to cover screenshots, OCR, and recording; do not add a recording-specific guide or restructure Preferences. This revised plan still requires approval before code changes. Unrelated Minor findings remain out of scope.

## Safety and scope

- Current release candidate is local commit `ca73c9e` on `release/v1.1.0`; preserve it. Do not amend/rebase it, push, open a PR, merge, tag, or create a Release as part of this plan.
- Do not change the version number. Add a `### Fixed` subsection under the existing `[1.1.0]` changelog entry when implementing; it currently contains `### Added` only.
- No dependency, CI, entitlements, minimum-OS, or broad recording-pipeline refactor changes. If the quit-flow test target needs new sources, update `project.yml` and regenerate with XcodeGen; never hand-edit the generated `.xcodeproj`.
- **I4 scope selected and authorized, pending approval of this revised plan:** preflight recording with the existing checker and route unavailable access to the same permission guide used by screenshot capture. Update that shared guide's existing copy in all four locales to mention recording. Do not add a second guide, a Preferences permission section, or merge the Capture and Recording Preferences sections. No new permission request, `PermissionService` behavior, TCC policy, or entitlement change is authorized.
- Automated tests can prove pure decisions and transaction safety, but cannot prove ScreenCaptureKit permissions, hardware encoding, audio sync, or real filesystem behavior. Those remain manual acceptance requirements.

## Findings and decisions

### C1 — Publication failure on destinations that do not support hard links

The review's phrasing that publication may overwrite an existing final file is inaccurate. `FileManager.linkItem` fails when the destination already exists, and `RecordingOutputTransactionTests` verifies the existing final file remains unchanged. The actual blocker is that `publish()` relies only on hard links; exFAT generally does not support them, while SMB/NAS behavior depends on server and client configuration. In that case a fully written recording is not published and remains under a hidden `.partial` name.

**User-selected contract — atomic publication only:** Preserve the existing no-overwrite behavior. `renameatx_np(RENAME_EXCL)` is available before the macOS 13 deployment target; the real constraint is whether the mounted volume advertises `VOL_CAP_INT_RENAME_EXCL` and accepts the operation. Publish using a hard link or exclusive rename only when supported; otherwise fail closed with an actionable unsupported-destination error. Never use plain `moveItem`, replace semantics, or a fallback that can overwrite.

This contract narrows supported custom destinations: any volume that supports neither operation remains unsupported, including any exFAT/SMB/NAS target where both operations fail. The limitation is accepted only within that explicit boundary; do not advertise broad exFAT/SMB support without volume-specific validation. The considered copy fallback (`O_CREAT|O_EXCL` plus copy/verify) is not selected because a partially copied final name can become visible.

Inject a narrow publisher seam so unsupported hard-link/rename, collision, successful atomic publication, and fail-closed behavior are deterministic in tests.

**Final-file mode decision:** The user declined a product requirement for final MP4 files to be `0600`. Do not add chmod/fchmod enforcement or final-mode tests; the `0600` reservation placeholder does not establish a final artifact requirement. Do not describe a retained partial as “recoverable” unless playability has actually been established; report only that a retained partial path is available.

**Adjacent risk included in C1 validation:** `reserveURLs` checks for a partial path and then creates it, so concurrent processes could race on the hidden partial even though final-file publication itself refuses collisions. Do not assume single-instance behavior: the repository has no confirmed single-instance guard. Inspect launch configuration and test whether a second app instance can be started. If it can, make the partial path transaction-specific (UUID independent of the final timestamp-based name) and create it atomically with `O_CREAT|O_EXCL`; keep the transaction UUID/path in memory and reuse the exact path for the writer's lifetime even when `prepareForWriting()` removes the placeholder. Test the exclusive-create primitive directly and use an injected identifier source to assert distinct transaction paths; do not rely on timing-only race tests or claim multi-process safety from final-file collision tests alone.

**C1 reservation detail:** the transaction-specific UUID/path itself is the reservation: create it atomically with `O_CREAT|O_EXCL`, keep the UUID/path in the transaction, and have the writer reuse that exact path after removing its placeholder. No separate reservation directory is required unless a distinct locking mechanism is introduced.

### I3 — Quit decision races with recording finalization

`NSAlert.runModal()` runs a nested event loop. Recording may finish or fail while the alert is open; after the user confirms, `stopAndSave()` can see `.idle` and return `false`, cancelling quit even though the recording already saved. A `Bool` also conflates “there is no longer an active recording” with “saving failed”.

**Decision:** Preserve the terminal outcome independently of the transient `.idle` status. Use distinct outcomes (`saved`, `noActiveSession`, `failed`): user cancellation, picker failure, and a start failure before a recording session becomes active are `noActiveSession`; once recording has started, no-frame, stream, writer/append, stop, finalization, or publication failures are `failed`. An accepted video sample is the threshold for retaining a partial, not the sole test for whether a session failure occurred. After the alert, use the saved outcome rather than inferring success from `.idle`; if finalization is already in progress, join the existing finalization or registered waiters rather than assuming a stored `Task` handle; cancel only when the saved outcome is `failed`. Guard against a second Quit request while the alert or wait is active. If Quit is requested when status is already `.saving`, skip the misleading “Stop and Save” alert and wait for the current finalization. Keep the existing `.terminateLater`/reply handoff; do not introduce a timeout or synchronous termination loop.

### I4 — Recording start does not enter the existing shared permission guide

Screenshots check `CaptureOrchestrator.checkPermissionStatus()` and open the existing permission window. Recording goes directly to the source picker; a permission-related `SCShareableContent` failure currently becomes a generic toast. The existing `onOpenPermissionGuide` callback is already wired to the permission window.

**User-selected design (authorized; this revised plan still needs approval):** There is one existing permission guide/window shared by screenshot capture and recording, so reuse it rather than creating another guide or moving permissions into Preferences. Keep the existing guide key and update its copy in all four locales to say the same screen-capture permission supports screenshots, OCR, and screen recording. Do not merge the separate Capture and Recording Preferences sections. Set `.selectingSource`, then asynchronously preflight with the existing `checkPermissionStatus()` before presenting the picker. After the await, verify the session is still `.selectingSource` so cancel/re-entry cannot reopen it. The check's `false` result means capture access is unavailable; it is not proof of a TCC denial because the existing ScreenCaptureKit-based check can also fail for transient/no-display reasons. Open the shared guide without claiming a confirmed denial. The existing permission checker caches successful results for 2 seconds: a picker failure immediately after a successful preflight may therefore recheck as available even if access was just revoked. Preserve the toast for that cached-success race and record it as a residual limitation; do not bypass the cache or modify `PermissionService`. Do not change permission requests, TCC policy, or entitlements.

**Approaches considered:** Reusing the existing guide and shared system-setting link is selected because the app already has one permission surface and one permission state. Adding a new Preferences permission section or merging Capture/Recording Preferences was not selected; neither is needed for the I4 preflight and both would broaden the UI refactor.

### I6 — Odd encoded dimensions from fractional or odd source geometry

`outputDimensions` may return fractional dimensions; `RecordingStreamSettings` independently rounds them to integers. Odd pixel dimensions can be rejected by some H.264/HEVC encoder configurations, but rejection is encoder-dependent and must not be described as inevitable. The current source rectangle is in display points; output dimensions are pixels.

**Decision:** Derive both output axes from one scale factor, then floor each to the largest even pixel size that does not exceed the scaled source dimensions or configured limits. Do not use separate per-axis scale factors, round up, or pixel-round the point-based `sourceRect`; even-flooring reduces each axis by less than 2 px, but the resulting aspect-ratio error is not bounded in percentage terms for very small regions. If either axis cannot yield a valid even size of at least 2 px without exceeding the source/limit, reject it as invalid rather than silently enlarging it. Pass the same computed dimensions to ScreenCaptureKit and AVAssetWriter; do not add an unused `destinationRect` adjustment.

### I7 — Writer and engine failure decisions are not deterministically tested

The only recording failure test covers `RecordingFailureRelay`. Engine start/stop, writer completion, no-frame, append rejection, stop errors, publication failures, and start-failure cleanup have no deterministic coverage. Do not build a complete fake AVAssetWriter or rewrite the sample pipeline.

**Decision:** Extract a small pure finalization/failure decision function and test it with writer state and captured errors as inputs. `hasStartedWriting` is not proof that a video frame was accepted: track `hasAcceptedVideoSample` only after `videoInput.append` succeeds. Use that accepted-frame state (not file size alone) to decide whether to delete an empty/header-only partial or retain a partial path. A retained file is not guaranteed playable. Keep `stopError` conservative: do not publish a file whose finalization reported an error merely because it might be playable.

## Implementation tasks (test first)

### Task 1 — Preserve no-overwrite publication on custom destinations (C1)

**Files**

- `Packages/CaptureCore/Sources/RecordingOutputTransaction.swift`
- `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingOutputTransactionTests.swift`
- `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift` only for consuming the transaction result/partial metadata
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- `App/SnapGlass/Sources/AppLocalization.swift` and four `Localizable.strings` files only if actionable publication/partial wording is needed

**Steps**

1. Add transaction tests for an unchanged existing final file, unsupported-hard-link and unsupported-exclusive-rename handling, `EEXIST` without overwrite, fail-closed behavior when neither atomic operation is supported, and successful atomic publication. Eligibility/retention based on accepted video samples is defined and tested in Task 5; this task only verifies transaction path/state behavior. Use an injected publisher seam; do not pretend it simulates real exFAT/SMB behavior.
2. Inspect launch configuration and manually check whether a second app instance can run. If so, make the partial path transaction-specific (UUID independent of the final timestamp name) and create it using `O_CREAT|O_EXCL`. Keep that UUID in the transaction and reuse the exact path for the writer; because every app transaction generates a distinct UUID, no other normal transaction will select the path after `prepareForWriting()` removes the placeholder, while `O_EXCL` rejects an already-present path at reservation time. Test the exclusive-create primitive directly and use an injected identifier source to assert distinct paths; do not rely on timing-only concurrent tests.
3. Do not test partial playability/retention policy in this task; Task 5 owns the accepted-video-sample eligibility rule and tests. Keep transaction tests limited to path reservation/publication state.
4. Implement only the selected atomic-only contract: use hard-link or exclusive rename when supported; query/verify `VOL_CAP_INT_RENAME_EXCL` and test actual volume behavior. If neither is supported, return the actionable unsupported-destination error and do not create/copy a final file. Never use plain move/replace or copy semantics. Keep the existing collision guarantee.
5. Do not add final-file `0600` enforcement or change final permissions; the user declined that requirement. Keep the reservation-placeholder mode separate from the final MP4 policy.
6. Map publication/finalization failures to concise localized text via `AppLocalization`, either by mapping the transaction error there or wrapping it as a `ScreenRecordingEngineError`; do not rely on enum-default `localizedDescription`. If a partial remains, say it was retained and provide its path, without promising playability. Add matching four-language keys for new UI text.
7. Confirm there is no copy fallback path and that unsupported volumes fail closed without exposing a partially copied final file.
8. Run `swift test --package-path Packages/CaptureCore`, `bash scripts/check-localization.sh`, and `bash scripts/test.sh` so App-facing publication errors are compiled by the App test scheme.

**Filesystem boundary:** Unit tests cover policy and error branches only. Manually exercise APFS, exFAT, and the actual supported SMB/NAS targets. Under the selected atomic-only contract, a volume is supported only if hard-link or exclusive rename works; otherwise fail closed and document that destination as unsupported. Do not validate or claim copy-fallback support.

### Task 2 — Make Quit wait for the actual recording outcome (I3)

**Files**

- `App/SnapGlass/Sources/AppLifecycleDelegate.swift`
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift` for a quit-specific outcome wrapper while preserving the existing menu-bar stop/save API
- `project.yml` for the explicit `WindowLifecycleStateTests` source list
- Add `App/SnapGlass/Tests/RecordingQuitFlowTests.swift` and the production quit-flow helper to that test scheme's explicit source list
- Run `xcodegen generate`; never hand-edit the generated `.xcodeproj`.
- `App/SnapGlass/Resources/{en,ja,ko,zh-Hans}.lproj/Localizable.strings` only if the alert wording changes

**Steps**

1. Add deterministic tests for save completion while confirmation is open, finalization failure, picker/start failure, cancellation during countdown, already-running save, duplicate Quit, and a post-start no-frame or stream/writer failure mapping to `.failed` and cancelling Quit. Test the pure helper, not `NSAlert` itself; partial-retention assertions remain in Task 5.
2. Persist an explicit terminal outcome scoped to the current recording session: `.saved` for successful publication; `.noActiveSession` for user cancellation, picker/preflight failure, or failure before the recording session becomes active; `.failed` for a recording-session error after start, including no-frame, stream, writer/append, stop, finalization, or publication failure. Clear the prior outcome when a new session begins. Do not infer the outcome from `.idle` alone or reuse a stale outcome from an earlier session. Retain a partial only according to the separate accepted-video-sample rule in Task 5.
3. Expose a quit-specific async outcome method through `CaptureViewModel+Recording.swift`, keeping the existing menu-bar `stopRecordingAndSave()` signature/behavior intact. If that cannot be preserved, include and update `MenuBarView.swift` call sites.
4. After the modal returns, read the retained terminal outcome: permit quit for `.saved`/`.noActiveSession`, cancel for `.failed`, and if finalization is still active join its existing finalization or registered waiters rather than starting a second stop.
5. When a quit request arrives while already `.saving`, skip the “Stop and Save” alert and wait for completion. Guard the alert/wait interval against repeated Quit and preserve `.terminateLater`/`reply(toApplicationShouldTerminate:)` sequencing.
6. Update the explicit `WindowLifecycleStateTests` source list in `project.yml`, run `xcodegen generate`, then run that scheme and `bash scripts/test.sh`. Confirm generated project changes are not manually edited or committed as source.

### Task 3 — Add recording preflight to the shared permission guide (I4; authorized, pending revised-plan approval)

**Files**

- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift`
- `App/SnapGlass/Sources/MenuBar/CaptureViewModel+Recording.swift` only if the existing callback wiring needs adjustment; it already opens the shared permission window
- `project.yml` for the explicit App test source list if the pure decision test is added there; regenerate with XcodeGen and never edit `.xcodeproj`
- `App/SnapGlass/Resources/{en,ja,ko,zh-Hans}.lproj/Localizable.strings` to update the existing shared permission-guide explanation in all four locales

**Steps, only after the user approves this revised plan**

1. Add a deterministic pure decision test for access available/unavailable, cancellation during the await, and picker failure followed by an access recheck.
2. Set status to `.selectingSource`, then run `checkPermissionStatus()` asynchronously before `RecordingSourcePickerPanel.show`. After the await, recheck that status is still `.selectingSource`; if the check reports unavailable, invoke `onOpenPermissionGuide` and return to idle without showing the picker.
3. Treat a `false` check as “capture access unavailable”, not proof of TCC denial. Do not use denial-specific wording when the checker can also fail because of transient/no-display conditions.
4. Handle picker failure in the controller's `onFailure` callback: synchronously capture the start-attempt identifier and launch a Task for the permission recheck; do not await it. Allow `onComplete(nil)` to finish selection cleanup. Do not require status to remain `.selectingSource` when the async recheck returns, because completion may already have moved the controller to `.idle`; ignore the result only if a newer start attempt superseded it. Open the existing guide only if the recheck remains false; otherwise preserve the current picker error toast. Because successful checks are cached for 2 seconds, a failure immediately after a successful preflight may hit the cache and remain a toast; do not claim this narrow revocation race is closed without separately authorized cache-bypass/error-classification work.
5. Do not add a new permission request, alter `PermissionService`, use `CGPreflightScreenCaptureAccess()` as the sole gate, or change entitlements/TCC policy.
6. Update the existing permission-guide description key in all four locales so it covers screenshots, OCR, and screen recording; do not add a recording-only guide, separate setting, or new permission request.
7. Run `bash scripts/test.sh` and `bash scripts/check-localization.sh`. Perform the permission-state GUI checks below; a unit-test pass cannot verify TCC.

### Task 4 — Produce even output pixel dimensions without changing source geometry (I6)

**Files**

- `Packages/CaptureCore/Sources/RecordingConfiguration.swift`
- `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`
- `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingConfigurationTests.swift`
- `App/SnapGlass/Sources/AppLocalization.swift` and four `.strings` files if a new `invalidOutputDimensions` error needs app-facing localization

**Steps**

1. Add pure tests for odd/fractional source sizes (`2561×1441` under 1080p, `1366×769`, odd 1× window, fractional region) and invalid/zero/1×N inputs. Valid output axes must be even, at least 2 px, and no larger than either source or configured limits.
2. Add an internal pure helper returning an optional validated even pixel size using one scale factor and even-floor per axis. Keep existing public `outputDimensions` semantics unless a test proves they must change, but require `RecordingStreamSettings.make` and engine start to consume this helper so production and geometry calculations cannot drift. Keep the helper internal where practical; add DocC if it must be public.
3. Before creating the stream or writer, have `ScreenRecordingEngine.start` reject a nil/invalid size with an explicit `invalidOutputDimensions` error. Change `RecordingStreamSettings.make` to accept validated dimensions (or propagate a typed error); remove the `max(1, …)` path that can silently turn invalid dimensions into 1×1.
4. Pass the exact same validated integer dimensions to `SCStreamConfiguration` and AVAssetWriter. Add a regression assertion that `RecordingStreamSettings.make` consumes the new helper's result and the writer receives those same dimensions. Keep `sourceRect` in display-point coordinates; do not alter `destinationRect` without a failing test.
5. Run `swift test --package-path Packages/CaptureCore`; if `AppLocalization` or App-facing error mapping changes, also run `bash scripts/check-localization.sh` and `bash scripts/test.sh` to compile the App.

### Task 5 — Cover writer lifecycle decisions and start-failure cleanup (I7)

**Files**

- `Packages/CaptureCore/Sources/ScreenRecordingEngine.swift`
- `Packages/CaptureCore/Sources/RecordingOutputTransaction.swift`
- `App/SnapGlass/Sources/Recording/RecordingSessionController.swift` for surfacing retained-partial paths
- `App/SnapGlass/Sources/AppLocalization.swift` and four `.strings` files if user-facing error text changes
- Add `Packages/CaptureCore/Tests/CaptureCoreTests/RecordingWriterLifecycleTests.swift`
- Existing `RecordingFailureNotificationTests.swift` only if the new policy fits its scope

**Steps**

1. Add tests for a pure writer-finalization decision seam before changing the pipeline: no accepted video sample even after `startWriting()`; first append rejection; accepted frame followed by append failure; stream/writer failure; writer not completed; prior failure after writer completion; stop error; publish failure; and successful single publication.
2. Extract only the decision logic from `RecordingWriterPipeline.finishAndPublish`; do not fake AVAssetWriter or redesign sample delivery.
3. Track `hasAcceptedVideoSample` only after `videoInput.append` returns true; `hasStartedWriting` alone is insufficient. Use accepted-frame state to classify no-frame sessions.
4. On start failure before a recording session becomes active, or on any terminal path with no accepted video sample, delete the partial (including a non-empty MP4 header). A stop/finalization failure after an accepted sample is `.failed` and retains a partial path; a post-start failure before the first accepted sample is also `.failed` for Quit purposes but deletes the header-only partial. A retained path is not a promise of playability.
5. Ensure stop errors and writer-finalization errors do not publish uncertain output. Carry an eligible partial URL through a structured engine error or read it from the engine before the controller clears it; map user-facing text through `AppLocalization`, not enum-default `localizedDescription`.
6. Reuse the C1 publisher seam for publication failure and success tests. Verify the transaction state does not allow duplicate publication.
7. Run `swift test --package-path Packages/CaptureCore`, `bash scripts/check-localization.sh`, and then `bash scripts/test.sh`.

### Task 6 — Record confirmed v1.1.0 fixes

**Files**

- `CHANGELOG.md`

**Steps**

1. After implementation scope is confirmed, add a `### Fixed` subsection under `## [1.1.0]` with only fixes that actually shipped. Do not claim unperformed GUI/hardware acceptance or support for unverified destinations.
2. Keep the version at 1.1.0 and run repository version validation and `git diff --check` before requesting review.

## Manual GUI/hardware acceptance (required before stable release)

### Permissions and picker

- First grant, deny, revoke an existing grant, return from System Settings, retry, and restart. Verify screenshot and recording paths open the same permission guide/system-setting item; confirm its shared localized explanation mentions screenshots, OCR, and recording. When the existing check reports capture access unavailable, verify the guide opens; separately simulate no-display/transient SCK failure and ensure the UI does not state that TCC denial was confirmed. Revoke access immediately after a successful preflight and verify/document the known 2-second success-cache residual (the picker may show a toast rather than the guide). Confirm no second guide or Preferences permission section was introduced.
- Test on macOS 13 and supported newer versions, including macOS 15+ ad-hoc signing. Record that no new permission/TCC policy was introduced.

### Sources, encoding, audio, and lifecycle

- Record display, window, and region sources on Retina and 1× displays, including multi-display, full-screen, moved/resized windows, disconnect, lock, sleep/wake, and source removal.
- Exercise odd/fractional window and region dimensions with H.264 and HEVC on macOS 13 and macOS 14+; play the results and verify size, duration, frame rate, and audio track, including any small aspect-ratio fill/crop difference from even-floor dimensions.
- Record 30 seconds and 5 minutes with system audio on/off; check A/V sync, HUD exclusion, frame pacing, and repeated start/stop.
- Test Quit during selection, countdown, start, active recording, and saving; reproduce save completion while the modal alert is open; test start failure and repeated Quit.

### Output transaction and failures

- Test default/custom APFS, exFAT removable media, and the actual supported SMB/NAS configurations. Verify collision suffix behavior and that existing files are never changed; evaluate success/failure against the selected atomic-only contract.
- Test unsupported hard links, `VOL_CAP_INT_RENAME_EXCL` reporting, destination permission denial, read-only volume, drive removal, rename failure, and interruption. Verify unsupported destinations fail closed without a final file; no copy fallback or incomplete-final visibility is expected. Do not call a retained partial recoverable.
- Test a second app instance in a controlled manual run. If it can start, verify independent transactions never share or truncate the same partial path.
- Do not add or assert a final-file `0600` requirement; the user explicitly declined it.

## Completion gates

- CaptureCore tests, App lifecycle tests, repository test script, and localization check pass. Add a `### Fixed` subsection under the existing `[1.1.0]` CHANGELOG entry; do not bump the version. Keep new helpers internal where practical; add DocC comments for any new public API. Run SwiftLint and SwiftFormat on changed files; report existing warnings/diagnostics rather than suppressing them.
- Record all manual acceptance separately. Do not mark GUI, permission, encoding, A/V, or filesystem behavior verified based on code review or unit tests.
- I4 is authorized within the selected shared-guide scope, but remains unimplemented until this revised plan is approved. Stable publication remains blocked until both recording and screenshot-shelf plans are completed, combined changes are re-reviewed, required hardware acceptance is recorded, author email/privacy is resolved, and a new Gate 2 is approved.
