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
placeholders() {
    grep -E '^"[^"]+" = ' "$1" | while IFS= read -r line; do
        key=$(printf '%s' "$line" | sed -E 's/^"([^"]+)".*/\1/')
        value=$(printf '%s' "$line" | sed -E 's/^"[^"]+" *= *"(.*)";[[:space:]]*$/\1/')
        specs=$(printf '%s' "$value" | grep -oE '%[0-9]*[@dfs]' | sort | tr '\n' ',' || true)
        printf '%s\t%s\n' "$key" "$specs"
    done | sort
}
placeholders "$RESOURCES/$REFERENCE.lproj/Localizable.strings" > /tmp/checkloc_ref.txt
for lang in "${LANGS[@]}"; do
    [ "$lang" == "$REFERENCE" ] && continue
    placeholders "$RESOURCES/$lang.lproj/Localizable.strings" > /tmp/checkloc_lang.txt
    diff_out=$(diff /tmp/checkloc_ref.txt /tmp/checkloc_lang.txt || true)
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

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "❌ Localization check failed"
    exit 1
fi
echo "✅ Localization check passed"
