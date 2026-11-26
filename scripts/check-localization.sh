#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESOURCES="$PROJECT_ROOT/App/SnapGlass/Resources"
SOURCES="$PROJECT_ROOT/App/SnapGlass/Sources"

LANGS=(en zh-Hans ja ko)
REFERENCE="en"
FAILED=0

keys_of() {
    grep -oE '^"[^"]+"' "$1" | sort
}

# A malformed table loads as nothing, and every lookup then falls back to the
# development language — the whole app silently renders in English with no build
# error. The key-parity checks below cannot see this: they compare key *sets*, and
# a bad line yields an empty key that matches in all four files. Only a real parse
# catches it, so this runs first and is fatal.
echo "=== Table syntax (plutil) ==="
for lang in "${LANGS[@]}"; do
    file="$RESOURCES/$lang.lproj/Localizable.strings"
    if ! plutil -lint "$file" >/dev/null 2>&1; then
        echo "  ❌ $lang: Localizable.strings does not parse"
        plutil -lint "$file" 2>&1 | sed 's/^/     /'
        FAILED=1
    fi
done
[ "$FAILED" -eq 0 ] && echo "  ✅ all four tables parse"

echo "=== Duplicate keys (values must be identical) ==="
for lang in "${LANGS[@]}"; do
    file="$RESOURCES/$lang.lproj/Localizable.strings"
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        distinct=$(grep -F "$key = " "$file" | sed -E 's/^[^=]*= *//' | sort -u | wc -l | tr -d ' ')
        if [ "$distinct" -gt 1 ]; then
            echo "  ❌ $lang: $key has $distinct different values"
            FAILED=1
        fi
    done < <(keys_of "$file" | uniq -d)
done
[ "$FAILED" -eq 0 ] && echo "  ✅ no conflicting duplicates"

echo "=== Key parity against $REFERENCE ==="
for lang in "${LANGS[@]}"; do
    [ "$lang" == "$REFERENCE" ] && continue
    missing=$(comm -23 <(keys_of "$RESOURCES/$REFERENCE.lproj/Localizable.strings") \
                       <(keys_of "$RESOURCES/$lang.lproj/Localizable.strings"))
    extra=$(comm -13 <(keys_of "$RESOURCES/$REFERENCE.lproj/Localizable.strings") \
                     <(keys_of "$RESOURCES/$lang.lproj/Localizable.strings"))
    if [ -n "$missing" ]; then
        echo "  ❌ $lang missing keys:"; echo "$missing" | sed 's/^/     /'
        FAILED=1
    fi
    if [ -n "$extra" ]; then
        echo "  ❌ $lang extra keys:"; echo "$extra" | sed 's/^/     /'
        FAILED=1
    fi
    [ -z "$missing" ] && [ -z "$extra" ] && echo "  ✅ $lang key set matches"
done

echo "=== Placeholder parity against $REFERENCE ==="
# One pass per file. The previous version spawned three subprocesses (two sed, one
# grep) *per line* — roughly 7k processes — and spent about 43 seconds of the
# gate's runtime doing it. Same output, one process.
placeholders() {
    python3 - "$1" <<'PY'
import re
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for raw in handle:
        match = re.match(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"(.*)";\s*$', raw.rstrip("\n"))
        if not match:
            continue
        specs = sorted(re.findall(r"%[0-9]*[@dfs]", match.group(2)))
        # Match the original `tr '\n' ','` shape exactly: a trailing comma after
        # every specifier, nothing at all when there are none.
        joined = "".join(spec + "," for spec in specs)
        rows.append(f"{match.group(1)}\t{joined}")
if rows:
    # Trailing newline: the previous implementation ended with `sort`, which always
    # terminates the last line.
    sys.stdout.write("\n".join(sorted(rows)) + "\n")
PY
}
for lang in "${LANGS[@]}"; do
    [ "$lang" == "$REFERENCE" ] && continue
    diff_out=$(diff \
        <(placeholders "$RESOURCES/$REFERENCE.lproj/Localizable.strings") \
        <(placeholders "$RESOURCES/$lang.lproj/Localizable.strings") || true)
    if [ -n "$diff_out" ]; then
        echo "  ❌ $lang placeholder mismatch:"; echo "$diff_out" | sed 's/^/     /'
        FAILED=1
    else
        echo "  ✅ $lang placeholders match"
    fi
done

echo "=== Source-referenced keys present ==="
if ! python3 - "$SOURCES" "$RESOURCES/$REFERENCE.lproj/Localizable.strings" <<'PY'
import re, sys, pathlib
sources, catalog_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
catalog = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', catalog_path.read_text(encoding="utf-8"), re.M))
patterns = [
    re.compile(r'NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'AppLocalization\.string\(\s*"((?:[^"\\]|\\.)*)"'),
]
missing = set()
for path in sources.rglob("*.swift"):
    text = path.read_text(encoding="utf-8")
    for pattern in patterns:
        for match in pattern.finditer(text):
            if match.group(1) not in catalog:
                missing.add((match.group(1), path.name))
if missing:
    for key, name in sorted(missing):
        print(f"  ❌ {key!r} referenced in {name} but absent from catalog")
    sys.exit(1)
print("  ✅ all referenced keys exist")
PY
then
    FAILED=1
fi

echo "=== View code must not bypass the app language ==="
# 界面语言由应用设置决定；String(localized:)/NSLocalizedString 跟随系统语言，
# 会让同一窗口里混出两种语言。Routing/ 保留源码且不进产品构建，故排除。
violations=$(grep -rn -E 'String\(localized:|NSLocalizedString\(' "$SOURCES" \
    --include='*.swift' | grep -v '/Routing/' | grep -v '^[^:]*:[0-9]*: *//' || true)
if [ -n "$violations" ]; then
    echo "  ❌ use LocalizedStringKey inside views, AppLocalization.string() outside them:"
    echo "$violations" | sed 's/^/     /'
    FAILED=1
else
    echo "  ✅ no view-level String(localized:)"
fi

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "❌ Localization check failed"
    exit 1
fi
echo "✅ Localization check passed"
