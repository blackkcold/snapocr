# Unified Library — Next Round Plan

Date: 2026-11-25
Branch: `feat/unified-library`
Base: `9462f3b` (`release/v1.7.2`)

## Status

The unified History library is implemented for the P0 path: sidebar navigation,
list/grid views, recording groups with segments, search/filter/sort, favourites,
rename, delete, batch export, group merge with over-limit splitting, thumbnails,
inspector preview, colours, recoverable recordings, four-language strings.

This round additionally closed:

- HUD deep link for audio recordings (`LibraryDeepLink`), including the
  `Combine & Export` action.
- Export media resolution through `RecordingSessionLedger` +
  `RecordingPreviewService` (`RecordingMediaResolver`), with a legacy fallback.
- A headless `SnapGlassLibraryCLI` tool target and contract tests.
- A real-media merge export test using two 48 kHz CAF segments.
- Batch merge for multiple selected recordings of the same kind.
- Localization keys and CI/test-script integration.

The following work is still open. It is deliberately listed rather than marked
complete.

## Remaining issue register

| ID | Issue | Fix | Verification |
|---|---|---|---|
| L01 | Library services live in the App target; the CLI target compiles the same files again | Move services into `LibraryCore`; expose one public facade; let App and CLI share it | Build App + CLI; delete duplicated source lists |
| L02 | Screen-recording HUD does not carry a session ID into the deep link | Add the screen session ID to the HUD callback; test select + merge deep links | UI/agent test with a screen session |
| L03 | Export resolver falls back silently | Return a warning in the export result; show it in the UI | Fault-injection test where resolver fails |
| L04 | Screenshot undo is in-memory; quitting loses it | Add persistent trash to `HistoryCore` (`trash`, `restore`, `emptyTrash`, retention); add “Recently Deleted” | Delete → restart → restore; purge test |
| L05 | Only within-session merge is supported | Add `MergeSegmentRef` + multi-session `ExportPlan` assembly; order by time or drag | Two real sessions merged; duration/tracks verified |
| L06 | Manual grouping has metadata support only | Add group/ungroup UI; scan merges sessions by `groupID`; group title/favourite | UI + metadata round-trip |
| L07 | No recording retention/size policy | `RecordingRetentionService`; favourites exempt; default off; preview before deletion | Policy tests; preview count |
| L08 | No tags/notes UI | Inspector fields; search hits both | Metadata + search tests |
| L09 | No incremental refresh | FSEvents watcher + debounce; snapshot cache keyed by root/index mtime | Temp-root watcher test |
| L10 | Screenshots load all entries and all thumbnails | `HistoryCore.page(offset:limit:)` / search page; first page 200 | 1000-item first-paint budget |
| L11 | Thumbnail cache grows without bound | 30-day/500 MB/LRU maintenance; cache key includes mtime+size | Generate 1000; prune; hit-rate report |
| L12 | No live recording row | `RecordingActivityMonitor`; pinned live row, not a history item | UI test during recording |
| L13 | No Space Quick Look or drag export | `QLPreviewPanel`; decrypt screenshots to temp; `NSItemProvider` | Shortcut + drag UI test |
| L14 | Old `HistoryView`, `WindowsView`, Recordings window remain | Keep one compatibility release, then remove dead paths | Build + full test suite |
| L15 | ja/ko strings are bulk translations | Native review; glossary; pseudo-locale screenshots | Review checklist + localization script |
| L16 | Accessibility coverage is partial | VoiceOver order/labels, keyboard-only path, reduce motion/transparency, contrast | Accessibility Inspector + UI tests |
| L17 | Recordings are plaintext while screenshots are encrypted | Show storage/path disclosure; optional AES-GCM migration | Privacy copy test; encryption migration test |
| L18 | No real-media CLI end-to-end | `LibraryTestKit` real MP4/M4A + journal; `snapglass-library selftest --media` | CLI `selftest --media` green |
| L19 | No performance budgets | Signposts + `bench` command; cold/warm/scan/export numbers | CI/nightly thresholds |
| L20 | No visual acceptance | XCUITest screenshots at 720/900/1040, light/dark, empty/error/offline | Automated screenshots + user review |

## CLI surface (target)

```bash
snapglass-library roots list --json
snapglass-library scan --root <dir> --json
snapglass-library items list --section all|favourites|screenshots|audio|video --json
snapglass-library metadata set --session <uuid> --name "..." --favorite
snapglass-library export --session <uuid> --dest <dir> --layout byType --manifest --json
snapglass-library merge --plan-only --session <uuid> --json
snapglass-library merge --session <uuid> --dest <dir> --title "..." --json
snapglass-library delete --session <uuid> --trash --json
snapglass-library screenshot delete --id <uuid> --trash --json
snapglass-library screenshot restore --id <uuid> --json
snapglass-library thumbnails generate --session <uuid> --json
snapglass-library bench --screenshots 1000 --recordings 200 --json
snapglass-library selftest --root <dir> [--media] --json
```

Every command returns a versioned JSON envelope and a stable exit code. The
default is to refuse the user library unless `--allow-user-library` is passed.
Tests always use an isolated root or `SNAPGLASS_AGENT_ROOT`.

## Test modules

- `LibraryCoreTests`: metadata, filter, merge planning, retention, cache keys.
- `LibraryServiceTests`: scan/dedupe/offline/missing/duplicate roots; media
  resolver; delete; export; merge.
- `LibraryCLITests`: command parser, JSON schema, exit codes, dangerous-path
  rejection.
- `LibraryTestKit`: real media fixture, screenshot fixture, fault injection,
  1000-item performance fixture.
- `LibraryViewModelTests`: selection, action matrix, optimistic favourites,
  delete confirmation.
- `LibraryUITests`: sidebar, list/grid, group expansion, batch bar, export/merge
  sheets, empty/error/offline states.
- `LibraryPerformanceTests`: scan, first paint, scroll, memory, export/merge
  throughput.
- `LibraryAccessibilityTests`: VoiceOver, keyboard, reduce motion/transparency.
- `AgentScenarioTests`: `library-scan/export/merge/delete/recover` with the real
  app and an isolated root.

Fixtures live under `~/Library/Caches/SnapGlassTests/` because the recording
ledger rejects `/var` symlink components. Tests clean up after themselves.

## Phases and gates

1. **Architecture (1 week)**: move services into `LibraryCore`; one public
   facade; remove CLI source duplication. Gate: App + CLI build, all unit tests.
2. **Correctness (1.5–2 weeks)**: L01–L05, L18. Gate: real-media CLI e2e,
   screenshot trash, deep links, export warnings.
3. **P1 UX (2–3 weeks)**: L06–L12. Gate: UI tests + performance budgets.
4. **Polish (1–1.5 weeks)**: L13–L17, L19–L20. Gate: CLI/CI/UI/accessibility/
   localization all green.
5. **Rollout (0.5 week)**: feature flag, docs, CHANGELOG, compatibility route.

## Acceptance

- Every issue in the register is closed with a test or a user real-device check.
- `scripts/test-library.sh` is green: unit, real-media, CLI, localization.
- `snapglass-library selftest --media` covers scan → export → merge → delete.
- Performance budgets:
  - cold library < 2s (500 sessions), warm < 300ms
  - 1000 screenshots + 200 recordings: 60fps, no >50ms main-thread stall, <250MB
  - thumbnail < 500ms, cache hit >80%
  - scan 200 sessions < 1.5s warm
- XCUITest covers the main flows and produces screenshots.
- Real-device checklist (user): screen/mic TCC, external volume, >2h recording,
  actual playback/merge, dark/light, 720px window, VoiceOver.
