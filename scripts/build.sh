#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=""
OUTPUT_DIR=""
OPEN_FINDER=false
CREATE_DMG=false
EXPERIMENTAL=false
SIGN_MODE="auto"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --release-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --output-dir)
            # 兼容旧参数名，但不推荐使用
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --experimental|--exp)
            EXPERIMENTAL=true
            shift
            ;;
        --open)
            OPEN_FINDER=true
            shift
            ;;
        --dmg)
            CREATE_DMG=true
            shift
            ;;
        --sign)
            SIGN_MODE="required"
            shift
            ;;
        --no-sign)
            SIGN_MODE="adhoc"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--version X.Y.Z] [--release-dir PATH] [--experimental] [--dmg] [--sign|--no-sign] [--open]"
            echo ""
            echo "Options:"
            echo "  --version X.Y.Z      指定版本号（默认读取 version.txt）"
            echo "  --release-dir PATH   指定输出目录（默认 release/vX.Y.Z/）"
            echo "  --experimental|--exp 本地实验打包：输出唯一目录 release/exp-vX.Y.Z-<UTC时间戳>-<随机码>/，永不覆盖，用于多轮产物对比测试"
            echo "  --sign               用固定的 SnapGlass Code Signing 证书签名；缺少证书即失败（发版必用）"
            echo "  --no-sign            强制 ad-hoc 签名，仅供本地调试；这种产物无法自动更新"
            echo "  --open               构建后在 Finder 中显示产物"
            echo "  --dmg                同时生成品牌 DMG 与 SHA-256（实验打包文件名含同一 UTC 时间戳）"
            echo ""
            echo "缺省（auto）：本机存在签名材料时用证书签名，否则退回 ad-hoc 并给出警告。"
            echo "构建号取自 build.txt，写入 CFBundleVersion；发版前由 bump-version.sh 自增。"
            echo "每次打包取一个 UTC 时刻，写入已签名 App 的 SGBuildTimestamp 与 BUILD_INFO.json 的 buildDate。"
            echo "产物统一输出到 release/ 目录。正式发版用 release/vX.Y.Z/，本地实验打包用 release/exp-*/。详见 Docs/RELEASE.md。"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    VERSION="$(<version.txt)"
    VERSION="${VERSION//[[:space:]]/}"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version: $VERSION" >&2
    exit 1
fi

# Sparkle compares CFBundleVersion, not the marketing version. The counter must
# be strictly increasing across releases; bump-version.sh maintains it.
if [[ ! -f "build.txt" ]]; then
    echo "Missing build.txt (monotonic build number)" >&2
    exit 1
fi
BUILD_NUMBER="$(tr -d '[:space:]' < build.txt)"
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Invalid build number in build.txt: $BUILD_NUMBER" >&2
    exit 1
fi

if [[ "$EXPERIMENTAL" == true && -n "$OUTPUT_DIR" ]]; then
    echo "--experimental and --release-dir are mutually exclusive" >&2
    exit 1
fi

# One UTC instant per packaging run. The signed App's SGBuildTimestamp,
# BUILD_INFO.json buildDate, the experimental directory label and the
# experimental DMG name all derive from this single value, so a mixed or stale
# timestamp is visible in any artifact without opening the app.
BUILD_EPOCH="$(date -u +%s)"
BUILD_TIMESTAMP_ISO="$(date -u -r "$BUILD_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
BUILD_TIMESTAMP_COMPACT="$(date -u -r "$BUILD_EPOCH" +%Y%m%dT%H%M%SZ)"

if [[ -z "$OUTPUT_DIR" ]]; then
    if [[ "$EXPERIMENTAL" == true ]]; then
        RANDOM_SUFFIX="$(openssl rand -hex 3 2>/dev/null || echo "$$")"
        OUTPUT_DIR="release/exp-v${VERSION}-${BUILD_TIMESTAMP_COMPACT}-${RANDOM_SUFFIX}"
    else
        OUTPUT_DIR="release/v${VERSION}"
    fi
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    echo "Output already exists; refusing to overwrite: $OUTPUT_DIR" >&2
    echo "Remove it first or use --release-dir to specify a different directory." >&2
    exit 1
fi

APP_NAME="SnapGlass"
DERIVED_DATA_ROOT="${SNAPGLASS_DERIVED_DATA:-.build/DerivedData-release-universal}"
ARM64_DERIVED_DATA="${DERIVED_DATA_ROOT}-arm64"
X86_64_DERIVED_DATA="${DERIVED_DATA_ROOT}-x86_64"
ARM64_APP="$ARM64_DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
X86_64_APP="$X86_64_DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
OUTPUT_APP="$OUTPUT_DIR/${APP_NAME}.app"

echo "▸ Generating Xcode project"
xcodegen generate

build_architecture() {
    local architecture="$1"
    local derived_data="$2"
    echo "▸ Running Release build for v$VERSION ($architecture)"
    xcodebuild -project "SnapGlass.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -derivedDataPath "$derived_data" \
        -destination "platform=macOS,arch=$architecture" \
        build \
        ARCHS="$architecture" \
        ONLY_ACTIVE_ARCH=YES \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO
}

build_architecture "arm64" "$ARM64_DERIVED_DATA"
build_architecture "x86_64" "$X86_64_DERIVED_DATA"

if [[ ! -d "$ARM64_APP" || ! -d "$X86_64_APP" ]]; then
    echo "Build failed: architecture-specific app bundle is missing" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
ditto "$ARM64_APP" "$OUTPUT_APP"

OUTPUT_EXECUTABLE="$OUTPUT_APP/Contents/MacOS/$APP_NAME"
UNIVERSAL_EXECUTABLE="$OUTPUT_DIR/${APP_NAME}.universal"
lipo -create \
    "$ARM64_APP/Contents/MacOS/$APP_NAME" \
    "$X86_64_APP/Contents/MacOS/$APP_NAME" \
    -output "$UNIVERSAL_EXECUTABLE"
mv "$UNIVERSAL_EXECUTABLE" "$OUTPUT_EXECUTABLE"
lipo "$OUTPUT_EXECUTABLE" -verify_arch arm64 x86_64

# Stamp the build instant into the assembled bundle. This must happen after the
# universal copy/lipo and before any signing, so the signature seals the value.
APP_INFO_PLIST="$OUTPUT_APP/Contents/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

inject_build_timestamp() {
    if [[ ! -f "$APP_INFO_PLIST" ]]; then
        echo "✗ Missing assembled Info.plist: $APP_INFO_PLIST" >&2
        exit 1
    fi
    if "$PLIST_BUDDY" -c "Print :SGBuildTimestamp" "$APP_INFO_PLIST" >/dev/null 2>&1; then
        "$PLIST_BUDDY" -c "Set :SGBuildTimestamp $BUILD_TIMESTAMP_ISO" "$APP_INFO_PLIST" \
            || { echo "✗ Failed to update SGBuildTimestamp in $APP_INFO_PLIST" >&2; exit 1; }
    else
        "$PLIST_BUDDY" -c "Add :SGBuildTimestamp string $BUILD_TIMESTAMP_ISO" "$APP_INFO_PLIST" \
            || { echo "✗ Failed to add SGBuildTimestamp to $APP_INFO_PLIST" >&2; exit 1; }
    fi
    local written
    written="$("$PLIST_BUDDY" -c "Print :SGBuildTimestamp" "$APP_INFO_PLIST" 2>/dev/null)" || written=""
    if [[ "$written" != "$BUILD_TIMESTAMP_ISO" ]]; then
        echo "✗ SGBuildTimestamp read-back mismatch in $APP_INFO_PLIST (got '${written:-<empty>}', expected '$BUILD_TIMESTAMP_ISO')" >&2
        exit 1
    fi
    echo "▸ Stamped SGBuildTimestamp=$BUILD_TIMESTAMP_ISO"
}

inject_build_timestamp

source "$PROJECT_DIR/scripts/lib/signing.sh"

sign_with_certificate() {
    open_signing_keychain
    trap close_signing_keychain EXIT
    echo "▸ Signing with \"$SIGN_IDENTITY\""
    sign_app "$OUTPUT_APP"
    close_signing_keychain
    trap - EXIT
    assert_signed "$OUTPUT_APP"
    bash "$PROJECT_DIR/scripts/verify-build.sh" \
        --app "$OUTPUT_APP" \
        --version "$VERSION" \
        --build "$BUILD_NUMBER" \
        --require-ed-key
}

sign_adhoc() {
    echo "▸ Applying ad-hoc signature (development only; cannot auto-update)"
    codesign --force --sign - "$OUTPUT_APP"
    codesign --verify --deep --strict "$OUTPUT_APP"
}

case "$SIGN_MODE" in
    required)
        sign_with_certificate
        ;;
    adhoc)
        sign_adhoc
        ;;
    auto)
        if [[ -f "$SIGNING_DIR/$P12_FILE" ]]; then
            sign_with_certificate
        else
            echo "⚠️  No signing certificate at $SIGNING_DIR/$P12_FILE" >&2
            echo "⚠️  Falling back to ad-hoc. This build cannot install updates." >&2
            sign_adhoc
        fi
        ;;
esac

SIGNATURE_KIND="ad-hoc"
if codesign -dv --verbose=4 "$OUTPUT_APP" 2>&1 | grep -q "Signature=adhoc"; then
    SIGNATURE_KIND="ad-hoc"
else
    SIGNATURE_KIND="self-signed"
fi

cat > "$OUTPUT_DIR/BUILD_INFO.json" <<EOF
{
  "version": "$VERSION",
  "build": $BUILD_NUMBER,
  "buildDate": "$BUILD_TIMESTAMP_ISO",
  "kind": "$([[ "$EXPERIMENTAL" == true ]] && echo "experimental" || echo "release")",
  "buildId": "$([[ "$EXPERIMENTAL" == true ]] && basename "$OUTPUT_DIR" || echo "release/v${VERSION}")",
  "app": "${APP_NAME}.app",
  "configuration": "Release",
  "signature": "$SIGNATURE_KIND",
  "architectures": ["arm64", "x86_64"]
}
EOF

echo ""
echo "✅ App packaged: $OUTPUT_APP"
echo "✅ Build info:  $OUTPUT_DIR/BUILD_INFO.json"

# 更新 release/latest/ 快捷入口：始终指向最近一次打包的 app（相对路径软链，可移植）
LATEST_DIR="release/latest"
LATEST_APP="$LATEST_DIR/${APP_NAME}.app"
mkdir -p "$LATEST_DIR"
# 相对路径：从 release/latest/ 指向产物目录中的 app
LATEST_TARGET="$(python3 -c "import os,sys; print(os.path.relpath('$OUTPUT_APP', '$LATEST_DIR'))")"
rm -f "$LATEST_APP"
ln -s "$LATEST_TARGET" "$LATEST_APP"
echo "✅ Latest shortcut: $LATEST_APP -> $LATEST_TARGET"

if [[ "$CREATE_DMG" == true ]]; then
    DMG_ARGS=(--app "$OUTPUT_APP" --version "$VERSION" --output-dir "$OUTPUT_DIR")
    if [[ "$EXPERIMENTAL" == true ]]; then
        # Official DMG names stay canonical; only experimental builds carry the
        # UTC instant in the filename to distinguish side-by-side test builds.
        DMG_ARGS+=(--timestamp "$BUILD_TIMESTAMP_COMPACT")
    fi
    bash "$PROJECT_DIR/scripts/package-dmg.sh" "${DMG_ARGS[@]}"
fi

if [[ "$OPEN_FINDER" == true ]]; then
    open -R "$OUTPUT_APP"
fi
