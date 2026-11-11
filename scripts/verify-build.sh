#!/bin/bash
# Verifies a built SnapGlass.app before it is packaged or published.
#
# Checks, in order:
#   - bundle identifier and version metadata
#   - universal architecture slice presence
#   - certificate signature (not ad-hoc), no Hardened Runtime, deep verification
#   - designated requirement matches the recorded identity
#   - SUPublicEDKey matches the EdDSA key used to sign the appcast
#
# Usage:
#   verify-build.sh --app PATH [--version X.Y.Z] [--build N]
#                   [--require-ed-key] [--requirement FILE]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP=""
EXPECTED_VERSION=""
EXPECTED_BUILD=""
REQUIRE_ED_KEY=false
REQUIREMENT_FILE="$PROJECT_DIR/scripts/signing/identity.requirement.txt"
EXPECTED_BUNDLE_ID="com.snapglass.app"
EXPECTED_ARCHS=("arm64" "x86_64")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --version) EXPECTED_VERSION="$2"; shift 2 ;;
        --build) EXPECTED_BUILD="$2"; shift 2 ;;
        --require-ed-key) REQUIRE_ED_KEY=true; shift ;;
        --requirement) REQUIREMENT_FILE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "Missing app bundle: ${APP:-<none>}" >&2
    exit 2
fi

source "$PROJECT_DIR/scripts/lib/signing.sh"

fail() {
    echo "✗ $1" >&2
    exit 1
}

plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null
}

echo "▸ Verifying $APP"

bundle_id="$(plist CFBundleIdentifier)"
[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] \
    || fail "bundle identifier is '${bundle_id}', expected '$EXPECTED_BUNDLE_ID'"

if [[ -n "$EXPECTED_VERSION" ]]; then
    short_version="$(plist CFBundleShortVersionString)"
    [[ "$short_version" == "$EXPECTED_VERSION" ]] \
        || fail "CFBundleShortVersionString is '${short_version}', expected '$EXPECTED_VERSION'"
fi

if [[ -n "$EXPECTED_BUILD" ]]; then
    bundle_version="$(plist CFBundleVersion)"
    [[ "$bundle_version" == "$EXPECTED_BUILD" ]] \
        || fail "CFBundleVersion is '${bundle_version}', expected '$EXPECTED_BUILD'"
fi

for arch in "${EXPECTED_ARCHS[@]}"; do
    lipo "$APP/Contents/MacOS/SnapGlass" -verify_arch "$arch" 2>/dev/null \
        || fail "missing $arch slice"
done

assert_signed "$APP" || fail "code signature is not the release identity"

requirement="$(print_designated_requirement "$APP")"
if [[ -f "$REQUIREMENT_FILE" ]]; then
    expected_requirement="$(cat "$REQUIREMENT_FILE")"
    [[ "$requirement" == "$expected_requirement" ]] \
        || fail "designated requirement changed:
    actual:   $requirement
    expected: $expected_requirement
A changed requirement resets TCC permissions and makes Sparkle reject the update."
fi

if [[ "$REQUIRE_ED_KEY" == true ]]; then
    embedded_key="$(plist SUPublicEDKey || true)"
    [[ -n "$embedded_key" ]] || fail "Info.plist has no SUPublicEDKey"
    # The public key is committed: it is not secret, and comparing against the
    # repository copy proves every signed build can verify the feed this repo
    # publishes. The private-key match is proven by verify-appcast.py.
    public_key_file="$PROJECT_DIR/scripts/signing/sparkle_ed25519.pub"
    [[ -f "$public_key_file" ]] || fail "missing $public_key_file"
    signing_key="$(tr -d '[:space:]' < "$public_key_file")"
    [[ "$embedded_key" == "$signing_key" ]] \
        || fail "SUPublicEDKey does not match scripts/signing/sparkle_ed25519.pub.
The build would be unable to install any future update."
fi

echo "✅ Build verified: $bundle_id ${EXPECTED_VERSION:-?} (build ${EXPECTED_BUILD:-?})"
echo "   authority: $(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "   requirement: $requirement"
