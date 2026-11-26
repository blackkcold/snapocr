# Unified Library — Quality & Localization Notes

Status: automated checks are headless CLI/package tests only. UI, visual and
native-language acceptance are manual user steps. See
`Docs/AUTOMATION_POLICY.md`: this project does not automate the GUI or take over
the computer.

## Automated coverage

- `scripts/test-library.sh`:
  - LibraryCore unit tests (metadata, filters, merge planning, retention,
    thumbnail cache, manual-group projection)
  - real single-session and cross-session media merge tests
  - CLI contract tests, including `snapglass-library selftest --media`
  - localization key/placeholder checks
- `scripts/test-library-cli.sh` runs the headless CLI against isolated roots and
  also gates `l10n-check` and a small `bench --assert` run.
- `snapglass-library l10n-check` validates key parity, `%@`/`%d` placeholders,
  the approved library glossary and short-label width for en/zh-Hans/ja/ko.
- `snapglass-library bench` builds 1000 screenshots and 200 recording sessions
  in a temporary root, measures paging/search/thumbnails/scan/real-media export
  and RSS, and gates budgets with `--assert`. CI runs it nightly.
- `LibraryCommandRouterTests` covers the keyboard shortcut matrix and its
  availability rules.
- `WindowLifecycleStateTests`, `EditorInteractionTests`, `BarcodePanelTests`
  remain unit-level app schemes; they do not drive the GUI.

## Keyboard commands

| Key | Command | Availability |
|---|---|---|
| Space | Quick Look preview | A row is selected |
| Return | Open selected item | A row is selected |
| ⌘E | Export selection | A row or batch selection exists |
| ⌘⌫ | Delete selected item… | A row is selected |
| ⌘⇧F | Toggle favourite | A row is selected |
| ⌘A | Select all visible | The library is not empty |
| Esc | Clear selection | Something is selected |

The bindings live in `LibraryCommand` (`Packages/LibraryCore`) and are rendered
by the window as hidden shortcut buttons. They stay disabled until the grid has
focus, so typing in search, tags or notes never triggers a library command.
Real key delivery, focus order and IME behaviour still need a human pass.

## Visual regression (not automated yet)

Pixel goldens are deliberately absent. `LibraryView`/`LibraryRows` take
`CaptureViewModel` and reach into the recording stack, so compiling them into a
test bundle would drag in most of the app; rendering them without a test host
would also resolve the wrong localization bundle. A synthetic preview view
drawn only in tests would pass while the real UI regressed, so it would be
test theater.

Prerequisites for real offscreen goldens:

1. Introduce a small protocol for the few capture actions the library uses
   (open editor, recording status) and inject it instead of `CaptureViewModel`.
2. Move the library views into their own module (or a dedicated test target
   with an app test host).
3. Render with `ImageRenderer` at 720/900/1040 px, light/dark, four languages,
   and compare against goldens with an explicit pixel tolerance.

Until then, width overflow is covered headlessly by `snapglass-library
l10n-check`, and visual/locale acceptance stays in the manual checklist below.

## Manual UI acceptance

Do this by hand on a real Mac:

1. Open History from the menu bar.
2. Check the sidebar at 720, 900 and 1040px: All / Favourites / Screenshots /
   Audio / Video / Colors / Recently Deleted.
3. Open a multi-segment recording group; verify the segment list and Merge &
   Export.
4. Select two or more recordings; Group, then Ungroup.
5. Delete a screenshot; restore it from Recently Deleted after relaunch.
6. Open Space Quick Look on a recording and a screenshot; drag a recording to
   Finder.
7. Open Manage Storage and verify the retention preview count before cleanup.
8. Check dark/light, reduce motion, reduce transparency, and VoiceOver order.
9. Native Japanese/Korean review of the new library strings.

## Accessibility baseline

- Sidebar rows expose stable identifiers: `library.sidebar.<section>`.
- Search: `library.search`; selection mode: `library.select`.
- Cards/rows combine their children and expose type/date/duration labels.
- Batch actions use labelled buttons; destructive actions are marked.
- Manual VoiceOver and keyboard-only checks remain user acceptance steps.

## Localization glossary

| English | zh-Hans | ja | ko |
|---|---|---|---|
| Library | 资料库 | ライブラリ | 라이브러리 |
| All | 全部 | すべて | 전체 |
| Favourites | 收藏 | お気に入り | 즐겨찾기 |
| Screenshots | 截图 | スクリーンショット | 스크린샷 |
| Audio | 音频 | 音声 | 오디오 |
| Video | 视频 | ビデオ | 비디오 |
| Recently Deleted | 最近删除 | 最近削除した項目 | 최근 삭제된 항목 |
| Incomplete | 未完成 | 未完了 | 미완료 |
| Group | 归组 | グループ化 | 그룹화 |
| Ungroup | 取消归组 | グループ解除 | 그룹 해제 |
| Merge & Export | 合并并导出 | 結合して書き出す | 병합 및 내보내기 |
| Move to Trash | 移到废纸篓 | ゴミ箱に移動 | 휴지통으로 이동 |

`scripts/check-localization.sh` enforces key parity, placeholder parity and
source references. Native review is still required for tone and length.

## Rollback

- `SNAPGLASS_LEGACY_HISTORY=1` opens the previous History view.
- The unified library preference is `library_unified_enabled` (default true).
- The old Recordings window remains as a compatibility route for one release.
