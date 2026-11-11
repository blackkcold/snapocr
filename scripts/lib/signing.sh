#!/bin/bash
# Shared code-signing helpers for SnapGlass.
#
# Source this file from a build script. Every function runs in the caller's
# shell on purpose: the temporary keychain must stay on the search list only
# for the duration of one build.
#
# Required material (never committed; see Docs/SIGNING.md):
#   $SIGNING_DIR/SnapGlass.p12           certificate + private key
#   $SIGNING_DIR/SnapGlass.p12.password  its export password
#
# Environment overrides:
#   SIGN_IDENTITY   code signing identity (default: SnapGlass Code Signing)
#   SIGNING_DIR     directory holding the .p12 (default: ~/.config/snapglass/signing)
#   P12_FILE        default SnapGlass.p12
#   P12_PASSWORD_FILE default SnapGlass.p12.password

SIGN_IDENTITY="${SIGN_IDENTITY:-SnapGlass Code Signing}"
SIGNING_DIR="${SIGNING_DIR:-$HOME/.config/snapglass/signing}"
P12_FILE="${P12_FILE:-SnapGlass.p12}"
P12_PASSWORD_FILE="${P12_PASSWORD_FILE:-SnapGlass.p12.password}"

_SK_KEYCHAIN=""
_SK_KEYCHAIN_PASSWORD=""
_SK_WORKDIR=""
_SK_ORIGINAL_KEYCHAINS=()

_sk_require_material() {
    if [[ ! -f "$SIGNING_DIR/$P12_FILE" ]]; then
        echo "Missing signing certificate: $SIGNING_DIR/$P12_FILE" >&2
        echo "See Docs/SIGNING.md for how to restore it from 1Password." >&2
        return 1
    fi
    if [[ ! -f "$SIGNING_DIR/$P12_PASSWORD_FILE" ]]; then
        echo "Missing certificate password: $SIGNING_DIR/$P12_PASSWORD_FILE" >&2
        return 1
    fi
}

_sk_capture_keychains() {
    _SK_ORIGINAL_KEYCHAINS=()
    local line
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | tr -d '"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -n "$line" ]] && _SK_ORIGINAL_KEYCHAINS+=("$line")
    done < <(security list-keychains -d user)
}

# Creates an isolated keychain and puts it first on the user search list.
# The login keychain is never written to.
open_signing_keychain() {
    _sk_require_material || return 1

    _SK_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/snapglass-sign.XXXXXX")"
    _SK_KEYCHAIN="$_SK_WORKDIR/build.keychain-db"
    _SK_KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"

    security create-keychain -p "$_SK_KEYCHAIN_PASSWORD" "$_SK_KEYCHAIN" >/dev/null
    security set-keychain-settings -lut 3600 "$_SK_KEYCHAIN"
    security unlock-keychain -p "$_SK_KEYCHAIN_PASSWORD" "$_SK_KEYCHAIN" >/dev/null
    security import "$SIGNING_DIR/$P12_FILE" \
        -k "$_SK_KEYCHAIN" \
        -P "$(cat "$SIGNING_DIR/$P12_PASSWORD_FILE")" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    # Without a partition list codesign cannot use the key non-interactively.
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "$_SK_KEYCHAIN_PASSWORD" "$_SK_KEYCHAIN" >/dev/null

    _sk_capture_keychains
    security list-keychains -d user -s "$_SK_KEYCHAIN" "${_SK_ORIGINAL_KEYCHAINS[@]}"
}

# Restores the search list and deletes the temporary keychain. Safe to call
# twice, and safe to call after a failure.
close_signing_keychain() {
    if [[ ${#_SK_ORIGINAL_KEYCHAINS[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${_SK_ORIGINAL_KEYCHAINS[@]}" || true
    fi
    if [[ -n "$_SK_KEYCHAIN" && -e "$_SK_KEYCHAIN" ]]; then
        security delete-keychain "$_SK_KEYCHAIN" 2>/dev/null || true
    fi
    if [[ -n "$_SK_WORKDIR" ]]; then
        rm -rf "$_SK_WORKDIR" 2>/dev/null || true
    fi
    _SK_KEYCHAIN=""
    _SK_KEYCHAIN_PASSWORD=""
    _SK_WORKDIR=""
    _SK_ORIGINAL_KEYCHAINS=()
}

_sk_sign() {
    # Sparkle's XPC services ship with sandbox entitlements. Re-signing without
    # this flag silently drops them and the installer service stops launching.
    codesign --force --sign "$SIGN_IDENTITY" \
        --preserve-metadata=entitlements "$1"
}

# Sparkle ships nested code under Versions/B. Deepest first, framework last.
_sk_sign_sparkle() {
    local app="$1"
    local framework="$app/Contents/Frameworks/Sparkle.framework"
    local version_dir="$framework/Versions/B"
    local nested

    [[ -d "$version_dir" ]] || return 0

    for nested in "$version_dir/XPCServices/"*.xpc \
                   "$version_dir/Updater.app" \
                   "$version_dir/Autoupdate"; do
        [[ -e "$nested" ]] || continue
        _sk_sign "$nested"
    done
    _sk_sign "$framework"
}

# Signs every Mach-O file inside the bundle except the main executable and
# anything already covered by the Sparkle pass.
_sk_sign_macho_files() {
    local app="$1" executable="$2"
    local file
    while IFS= read -r file; do
        [[ "$file" == "$app/Contents/MacOS/$executable" ]] && continue
        case "$file" in
            */Sparkle.framework/*) continue ;;
        esac
        file "$file" 2>/dev/null | grep -q "Mach-O" || continue
        _sk_sign "$file"
    done < <(find "$app/Contents" -type f -perm -u+x 2>/dev/null)
}

# Signs nested bundles deepest first, then remaining frameworks. Sparkle is
# handled separately and skipped here.
_sk_sign_nested_bundles() {
    local app="$1"
    local bundle
    while IFS= read -r bundle; do
        case "$bundle" in
            */Sparkle.framework|*/Sparkle.framework/*) continue ;;
        esac
        # Only code bundles carry a MacOS directory or a Versions directory.
        if [[ -d "$bundle/Contents/MacOS" || -d "$bundle/Versions" ]]; then
            _sk_sign "$bundle"
        fi
    done < <(find "$app/Contents" -depth -type d \
        \( -name "*.xpc" -o -name "*.appex" -o -name "*.app" \
           -o -name "*.plugin" -o -name "*.bundle" -o -name "*.framework" \) \
        2>/dev/null)
}

# Full pass: Sparkle internals -> Mach-O files -> nested bundles -> app.
sign_app() {
    local app="$1"
    local executable

    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
        "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -z "$executable" ]]; then
        echo "Cannot read CFBundleExecutable from $app" >&2
        return 1
    fi

    _sk_sign_sparkle "$app"
    _sk_sign_macho_files "$app" "$executable"
    _sk_sign_nested_bundles "$app"
    _sk_sign "$app"
}

assert_signed() {
    local app="$1"
    local info authority flags

    info="$(codesign -dv --verbose=4 "$app" 2>&1 || true)"

    if printf '%s' "$info" | grep -q "Signature=adhoc"; then
        echo "$app is ad-hoc signed; a stable certificate is required." >&2
        return 1
    fi

    authority="$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)"
    if [[ "$authority" != "$SIGN_IDENTITY" ]]; then
        echo "$app is signed by '${authority:-unknown}', expected '$SIGN_IDENTITY'." >&2
        return 1
    fi

    # codesign prints the flags on the CodeDirectory line, e.g.
    #   CodeDirectory v=20400 size=... flags=0x10000(runtime) hashes=...
    flags="$(printf '%s\n' "$info" | grep -o 'flags=0x[0-9a-f]*([^)]*)' | head -1)"
    if [[ "$flags" == *"runtime"* ]]; then
        echo "$app has Hardened Runtime enabled; self-signed updates cannot load." >&2
        return 1
    fi

    codesign --verify --deep --strict "$app"
}

# Prints the designated requirement so CI can compare it with the recorded one.
print_designated_requirement() {
    codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}
