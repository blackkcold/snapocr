#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/snapglass-library-cli.XXXXXX")"
BENCH_ROOT="$HOME/Library/Caches/SnapGlassTests/cli-bench-$$"
cleanup() {
    rm -rf "$TMP_ROOT"
    rm -rf "$BENCH_ROOT"
}
trap cleanup EXIT

CLI="$PROJECT_DIR/scripts/library-cli.sh"

check_json_ok() {
    local payload="$1"
    python3 - "$payload" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
if payload.get("ok") is not True:
    raise SystemExit(f"expected ok=true, got {payload}")
PY
}

SELFTEST="$("$CLI" selftest --root "$TMP_ROOT" --json)"
check_json_ok "$SELFTEST"

MEDIA_SELFTEST="$("$CLI" selftest --root "$TMP_ROOT" --media --json)"
python3 - "$MEDIA_SELFTEST" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload.get("ok") is True, payload
assert payload.get("media") is True, payload
assert payload.get("mediaDuration", 0) > 1.5, payload
PY

L10N="$("$CLI" l10n-check --root "$PROJECT_DIR" --json)"
python3 - "$L10N" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload.get("ok") is True, payload
PY

mkdir -p "$BENCH_ROOT"
BENCH="$("$CLI" bench --root "$BENCH_ROOT" --screenshots 50 --recordings 20 --media-count 2 --assert --json)"
python3 - "$BENCH" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload.get("ok") is True, payload
PY

SCAN="$("$CLI" scan --root "$TMP_ROOT" --json)"
python3 - "$SCAN" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["ok"] is True, payload
assert payload["sessions"] == 0, payload
PY

"$CLI" help >/dev/null

echo "✅ Library CLI contract tests passed"
