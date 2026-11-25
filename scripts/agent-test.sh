#!/bin/bash
# Runs one SnapGlass recording scenario through the app's agent channel.
#
# Usage:
#   scripts/agent-test.sh <scenario.json> [--timeout 120] [--app <path>] [--keep] [--rebuild]
#
# The script builds a Debug app signed with the same stable identity as the
# installed copy, refuses to run when the designated requirements differ (that
# would trigger a second TCC grant), starts an isolated second instance with
# `open -n`, waits for report.json, and captures evidence when the run fails.
#
# It never touches the user's running instance, user library, or preferences.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

SCENARIO=""
TIMEOUT=120
APP_OVERRIDE=""
KEEP=false
FORCE_BUILD=false
SEED_DIR=""
REFERENCE_APP="${SNAPGLASS_AGENT_REFERENCE_APP:-/Applications/SnapGlass.app}"

usage() {
    cat <<'USAGE'
Usage: scripts/agent-test.sh <scenario.json> [--timeout 120] [--app <path>] [--keep] [--rebuild] [--agent-seed <dir>]

  <scenario.json>      Scenario file (see scripts/agent-scenarios/)
  --timeout <seconds>  Total wait for report.json (default 120)
  --app <path>         Use an existing signed app instead of building
  --keep               Keep the temporary output directory on success
  --rebuild            Force a Debug build even when the cached app is current
  --agent-seed <dir>   Copy an isolated session tree into the agent root first
                       (used by recover-orphan; never reads the user library)

Environment:
  SNAPGLASS_AGENT_REFERENCE_APP  Installed app whose signature must match
                                 (default /Applications/SnapGlass.app)
  SNAPGLASS_AGENT_SIGN_IDENTITY  Signing identity (default "SnapGlass Code Signing")
  SNAPGLASS_AGENT_SPM_CACHE      Existing SourcePackages directory for offline builds
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --app)
            APP_OVERRIDE="$2"
            shift 2
            ;;
        --keep)
            KEEP=true
            shift
            ;;
        --rebuild)
            FORCE_BUILD=true
            shift
            ;;
        --agent-seed)
            SEED_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -n "$SCENARIO" ]]; then
                echo "Only one scenario may be given" >&2
                exit 2
            fi
            SCENARIO="$1"
            shift
            ;;
    esac
done

if [[ -z "$SCENARIO" ]]; then
    usage >&2
    exit 2
fi
if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -le 0 ]]; then
    echo "--timeout must be a positive integer" >&2
    exit 2
fi
if [[ ! -f "$SCENARIO" ]]; then
    echo "Scenario not found: $SCENARIO" >&2
    exit 2
fi
SCENARIO="$(cd "$(dirname "$SCENARIO")" && pwd)/$(basename "$SCENARIO")"

DERIVED="$PROJECT_DIR/.build/agent-derived"
BUILT_APP="$DERIVED/Build/Products/Debug/SnapGlass.app"
SIGN_IDENTITY="${SNAPGLASS_AGENT_SIGN_IDENTITY:-SnapGlass Code Signing}"

echo "▸ Scenario: $SCENARIO"
echo "▸ Timeout:  ${TIMEOUT}s"

# --- build and sign ---------------------------------------------------------

signed_authority() {
    codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^Authority=//p' | head -1
}

bundle_identifier() {
    codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^Identifier=//p' | head -1
}

designated_requirement() {
    codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' | head -1
}

build_app() {
    echo "▸ Generating Xcode project"
    if ! xcodegen generate >/dev/null; then
        echo "✗ xcodegen generate failed" >&2
        return 1
    fi
    echo "▸ Building Debug app (arm64, unsigned; signed below)"
    local build_args=()
    if [[ -n "${SNAPGLASS_AGENT_SPM_CACHE:-}" ]]; then
        build_args+=(
            -clonedSourcePackagesDirPath "$SNAPGLASS_AGENT_SPM_CACHE"
            -disableAutomaticPackageResolution
            -skipPackageUpdates
        )
    fi
    if ! xcodebuild -project SnapGlass.xcodeproj \
        -scheme SnapGlass \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED" \
        ${build_args[@]+"${build_args[@]}"} \
        build \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY=; then
        echo "✗ xcodebuild failed" >&2
        return 1
    fi
    if [[ ! -d "$BUILT_APP" ]]; then
        echo "✗ Built app missing: $BUILT_APP" >&2
        return 1
    fi
    echo "▸ Signing with \"$SIGN_IDENTITY\""
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/scripts/lib/signing.sh"
    if ! open_signing_keychain; then
        echo "✗ Cannot open the signing keychain" >&2
        return 1
    fi
    if ! sign_app "$BUILT_APP"; then
        close_signing_keychain
        echo "✗ Signing failed" >&2
        return 1
    fi
    close_signing_keychain
    if ! assert_signed "$BUILT_APP"; then
        echo "✗ Signature verification failed" >&2
        return 1
    fi
}

needs_build() {
    [[ ! -d "$BUILT_APP" ]] && return 0
    [[ "$FORCE_BUILD" == true ]] && return 0
    [[ "$PROJECT_DIR/project.yml" -nt "$BUILT_APP" ]] && return 0
    local newer
    newer="$(find "$PROJECT_DIR/App" "$PROJECT_DIR/Packages" -type f -name '*.swift' \
        -newer "$BUILT_APP/Contents/MacOS/SnapGlass" -print -quit 2>/dev/null)"
    [[ -n "$newer" ]] && return 0
    return 1
}

if [[ -n "$APP_OVERRIDE" ]]; then
    APP="$(cd "$(dirname "$APP_OVERRIDE")" && pwd)/$(basename "$APP_OVERRIDE")"
    if [[ ! -d "$APP" ]]; then
        echo "App not found: $APP" >&2
        exit 2
    fi
else
    APP="$BUILT_APP"
    if needs_build; then
        build_app || exit 1
    else
        echo "▸ Reusing signed build at $APP"
    fi
fi

# --- signature consistency --------------------------------------------------

if [[ ! -d "$REFERENCE_APP" ]]; then
    echo "✗ Reference app not found: $REFERENCE_APP" >&2
    echo "  Pass SNAPGLASS_AGENT_REFERENCE_APP=<installed SnapGlass.app> to compare TCC identity." >&2
    exit 1
fi

REF_ID="$(bundle_identifier "$REFERENCE_APP")"
APP_ID="$(bundle_identifier "$APP")"
REF_DR="$(designated_requirement "$REFERENCE_APP")"
APP_DR="$(designated_requirement "$APP")"
APP_AUTHORITY="$(signed_authority "$APP")"

echo "▸ Reference: $REFERENCE_APP ($REF_ID)"
echo "▸ Test app:  $APP ($APP_ID, $APP_AUTHORITY)"
echo "▸ DR test:      $APP_DR"
echo "▸ DR reference: $REF_DR"

if [[ -z "$REF_DR" || -z "$APP_DR" ]]; then
    echo "✗ Cannot read designated requirements; refusing to run." >&2
    exit 1
fi
if [[ "$APP_ID" != "$REF_ID" || "$APP_DR" != "$REF_DR" ]]; then
    echo "✗ Test build does not share the installed app's TCC identity." >&2
    echo "  Running it would trigger duplicate microphone/screen authorization." >&2
    echo "  Fix the build signature instead of approving a second grant." >&2
    exit 1
fi

# --- isolation baseline -----------------------------------------------------

# The recording ledger rejects symlinked paths, and TMPDIR lives under /var,
# so agent runs live under the repository's real build directory.
AGENT_RUNS="$PROJECT_DIR/.build/agent-runs"
mkdir -p "$AGENT_RUNS"
OUT="$AGENT_RUNS/$(date +%Y%m%dT%H%M%S)-$$"
ROOT="$OUT/root"
mkdir -p "$ROOT"

if [[ -n "$SEED_DIR" ]]; then
    if [[ ! -d "$SEED_DIR" ]]; then
        echo "Seed directory not found: $SEED_DIR" >&2
        exit 2
    fi
    # A seed is a copy made by the caller. The agent then runs entirely inside
    # ROOT, so a recovery scenario never touches the source tree.
    ditto "$SEED_DIR" "$ROOT" || {
        echo "Cannot copy seed into the agent root" >&2
        exit 1
    }
    echo "▸ Seeded:      $SEED_DIR"
fi

snapshot_user_state() {
    local destination="$1"
    local path
    : > "$destination"
    for path in "$HOME/Movies/SnapGlass" "$HOME/Library/Application Support/SnapGlass"; do
        if [[ -d "$path" ]]; then
            local total newest
            total="$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')"
            newest="$(find "$path" -type f -exec stat -f '%m' {} + 2>/dev/null | sort -n | tail -1)"
            printf '%s\ttotal=%s\tnewest=%s\n' "$path" "$total" "${newest:-0}" >> "$destination"
        else
            printf '%s\tmissing\n' "$path" >> "$destination"
        fi
    done
    printf 'defaults_sha256=%s\n' \
        "$(defaults read com.snapglass.app 2>/dev/null | shasum -a 256 | awk '{print $1}')" >> "$destination"
}

snapshot_user_state "$OUT/user-before.txt"

echo "▸ Output: $OUT"

PID=""
REPORT="$OUT/report.json"

terminate_own_pid() {
    local target="$1"
    [[ -z "$target" ]] && return 0
    kill -0 "$target" 2>/dev/null || return 0
    kill "$target" 2>/dev/null || true
    local i
    for ((i = 0; i < 50; i++)); do
        kill -0 "$target" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -9 "$target" 2>/dev/null || true
}

collect_forensics() {
    echo "▸ Collecting forensics"
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        if sample "$PID" 3 -file "$OUT/sample.txt" >"$OUT/sample.err" 2>&1; then
            echo "  sample:     $OUT/sample.txt"
        else
            echo "  sample:     failed (see sample.err)"
        fi
        if spindump "$PID" -o "$OUT/spindump.txt" >"$OUT/spindump.err" 2>&1; then
            echo "  spindump:   $OUT/spindump.txt"
        else
            echo "  spindump:   skipped (needs privileges); see spindump.err"
        fi
    else
        echo "  sample:     skipped (process already exited)"
    fi
    if log show --last 3m --signpost --predicate 'subsystem == "com.snapglass"' \
        >"$OUT/signposts.txt" 2>&1; then
        echo "  signposts:  $OUT/signposts.txt"
    else
        echo "  signposts:  unavailable; see signposts.txt"
    fi
    {
        echo "# session files"
        find "$ROOT" -maxdepth 4 -type f 2>/dev/null | sort
        echo
        echo "# sizes"
        find "$ROOT" -maxdepth 4 -type f -exec ls -l {} + 2>/dev/null
    } >"$OUT/session-files.txt"
    echo "  session:    $OUT/session-files.txt"
}

# --- run --------------------------------------------------------------------

ARGS=(
    --agent-run "$SCENARIO"
    --agent-root "$ROOT"
    --agent-out "$OUT"
    --agent-hud-corner bottomLeading
)

DEADLINE="$(python3 -c \
    'import json,sys; d=json.load(open(sys.argv[1])); v=d.get("firstSampleDeadlineSeconds"); print("" if v is None else v)' \
    "$SCENARIO" 2>/dev/null || true)"
if [[ -n "$DEADLINE" ]]; then
    ARGS+=(--agent-deadline "$DEADLINE")
fi

echo "▸ Launching isolated instance"
open -n -g -a "$APP" --args "${ARGS[@]}" || {
    echo "✗ open failed" >&2
    exit 1
}

for ((i = 0; i < 300; i++)); do
    if [[ -s "$OUT/agent.pid" ]]; then
        PID="$(tr -d '[:space:]' < "$OUT/agent.pid")"
        break
    fi
    sleep 0.1
done
if [[ -z "$PID" ]]; then
    echo "✗ agent.pid was not written within 30s" >&2
    collect_forensics
    snapshot_user_state "$OUT/user-after.txt"
    diff -u "$OUT/user-before.txt" "$OUT/user-after.txt" >"$OUT/user-diff.txt" || true
    echo "▸ Evidence: $OUT"
    exit 1
fi
echo "▸ Agent pid:  $PID"

DEADLINE_AT=$(( $(date +%s) + TIMEOUT ))
while [[ ! -s "$REPORT" ]]; do
    if ! kill -0 "$PID" 2>/dev/null; then
        break
    fi
    if [[ "$(date +%s)" -ge "$DEADLINE_AT" ]]; then
        echo "✗ Timed out after ${TIMEOUT}s waiting for report.json" >&2
        break
    fi
    sleep 0.2
done

OK=false
if [[ -s "$REPORT" ]]; then
    OK="$(python3 - "$REPORT" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        print("true" if json.load(handle).get("ok") is True else "false")
except Exception:
    print("false")
PY
)"
fi

FORENSICS=false
if [[ "$OK" != true ]]; then
    collect_forensics
    FORENSICS=true
fi

# Wait briefly for a clean self-termination, then only ever signal our own pid.
for ((i = 0; i < 25; i++)); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.2
done
terminate_own_pid "$PID"

snapshot_user_state "$OUT/user-after.txt"
ISOLATION_OK=true
if ! diff -u "$OUT/user-before.txt" "$OUT/user-after.txt" >"$OUT/user-diff.txt"; then
    ISOLATION_OK=false
fi

ARTIFACT_COUNT="$(find "$ROOT" -maxdepth 2 -type f ! -path '*/.SnapGlassSessions/*' 2>/dev/null | wc -l | tr -d ' ')"

echo ""
if [[ -s "$REPORT" ]]; then
    echo "▸ Report summary"
    python3 - "$REPORT" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    report = json.load(handle)
print("  ok:          %s" % report.get("ok"))
print("  scenario:    %s" % report.get("scenario"))
print("  session:     %s" % json.dumps(report.get("session"), ensure_ascii=False))
print("  hud:         %s" % json.dumps(report.get("hud"), ensure_ascii=False))
print("  mainThread:  %s" % json.dumps(report.get("mainThread"), ensure_ascii=False))
print("  supervisor:  %s" % json.dumps(report.get("supervisor"), ensure_ascii=False))
print("  readiness:   %s" % json.dumps(report.get("readiness"), ensure_ascii=False))
for artifact in report.get("artifacts") or []:
    print("  artifact:    %s bytes=%s duration=%s" %
          (artifact.get("path"), artifact.get("bytes"), artifact.get("duration")))
for error in report.get("errors") or []:
    print("  error:       %s" % error)
PY
else
    echo "⚠ No report.json produced"
fi
echo "▸ Agent root artifacts: $ARTIFACT_COUNT"
if [[ "$ISOLATION_OK" == true ]]; then
    echo "▸ User library: unchanged"
else
    echo "✗ User library changed during the run:" >&2
    cat "$OUT/user-diff.txt" >&2
fi

RESULT=1
if [[ "$OK" == true && "$ISOLATION_OK" == true ]]; then
    RESULT=0
elif [[ "$FORENSICS" != true ]]; then
    # The process already exited, so only post-mortem evidence is available.
    collect_forensics
fi

if [[ "$RESULT" == 0 && "$KEEP" != true ]]; then
    rm -rf "$OUT"
    echo "✅ $SCENARIO passed (temporary output removed; use --keep to inspect)"
else
    echo "📁 Evidence retained: $OUT"
    echo "   report:   $REPORT"
    echo "   artifacts: $ROOT"
fi
exit "$RESULT"
