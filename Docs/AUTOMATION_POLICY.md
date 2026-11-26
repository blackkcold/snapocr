# Automation & Testing Policy

SnapGlass does not allow tests or agents to take over the user's computer or
drive the app's GUI.

## CUA / computer use — default deny

- Never move/click the mouse, send keyboard input, operate another app, capture
  the desktop, or launch/drive the product GUI.
- `cua-driver`, XCUITest, AppleScript/System Events, browser/desktop automation
  and simulated input are forbidden without explicit, task-scoped user
  permission. Project tests never receive that permission.
- Offscreen rendering inside a test process (`ImageRenderer`/`NSHostingView`)
  is allowed: it does not control the GUI or the desktop.
- Even with permission, prefer a headless route; if GUI control is truly
  required, state the exact scope and ask again.

## Test tiers

| Tier | Content | Gate |
|---|---|---|
| 1 | Package tests, CLI contracts, localization key/placeholder/glossary, keyboard command router | Every PR, hard |
| 2 | Offscreen visual golden at 720/900/1040, light/dark, four languages | Not automated yet: library views are coupled to `CaptureViewModel`; see `LIBRARY_QUALITY.md` |
| 3 | Headless benchmarks (1000 screenshots / 200 recordings) | Nightly, budget report |
| 4 | Real-device TCC, external volume, >2h recording, VoiceOver, native tone, real window material/FPS | User, release checklist |

## Allowed

- Headless CLI commands, for example:
  - `snapglass-library scan --root <isolated-root> --json`
  - `snapglass-library selftest --media --json`
  - `snapglass-library merge --session <uuid> --dest <dir> --json`
- Shell scripts that build, lint, run package tests, validate JSON contracts or
  inspect files.
- Unit and integration tests that use temporary/isolated roots.
- The isolated agent channel (`scripts/agent-test.sh` with
  `SNAPGLASS_AGENT_ROOT`), because it runs a separate app instance against a
  test root and reports JSON; it must never touch the user library or the
  user's running app.
- Manual UI/visual checks performed by a human.

## Not allowed

- XCUITest, AppleScript UI scripting, `osascript` clicks/keystrokes, coordinate
  automation, simulated input, or any process that launches and drives the
  product GUI.
- Screenshot automation that requires controlling the app or the desktop.
- Tests that read or mutate the user's real history, recordings, preferences or
  running SnapGlass instance.

## Rules for test roots

- Every command/test must use `--root`, `--history-root`, or
  `SNAPGLASS_AGENT_ROOT`.
- The CLI refuses the user library unless `--allow-user-library` is explicitly
  passed; automated tests must never pass it.
- Fixtures are created under `~/Library/Caches/SnapGlassTests/` or a dedicated
  temporary directory and are removed by the test.
- Real-device checks (screen/mic TCC, external volumes, >2h recordings,
  VoiceOver, visual acceptance) are manual user steps.

## Verification

- Headless tests: `scripts/test-library.sh`
- CLI contract: `scripts/test-library-cli.sh`
- Package tests: `swift test --package-path Packages/<Name>`
- App unit schemes: `WindowLifecycleStateTests`, `EditorInteractionTests`,
  `BarcodePanelTests`
- Localization: `scripts/check-localization.sh`

There is intentionally no automated UI-test target in this project.
