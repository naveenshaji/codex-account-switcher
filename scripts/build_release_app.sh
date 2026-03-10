#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Account Switcher"
APP_EXECUTABLE="CodexAccountSwitcherApp"
BUNDLE_ID="io.naveen.codex-account-switcher"
MIN_SYSTEM_VERSION="14.0"
OUTPUT_DIR="$ROOT_DIR/dist/release"
VERSION=""
BUILD_NUMBER=""
APPCAST_URL="${APPCAST_URL:-${SU_FEED_URL:-}}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SIGN_APP=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") --version <version> --build <build-number> [options]

Options:
  --version <version>              Marketing version (CFBundleShortVersionString)
  --build <build-number>           Build number (CFBundleVersion)
  --bundle-id <bundle-id>         Bundle identifier
  --appcast-url <url>             Sparkle appcast URL
  --public-ed-key <key>           Sparkle public Ed25519 key (SUPublicEDKey)
  --signing-identity <identity>   Developer ID Application identity; omit to leave bundle unsigned
  --output-dir <path>             Output directory (default: dist/release)
  --min-system-version <version>  LSMinimumSystemVersion (default: 14.0)
  --no-sign                       Skip codesigning even if SIGNING_IDENTITY is set
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required tool: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --build)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$2"
      shift 2
      ;;
    --appcast-url)
      APPCAST_URL="$2"
      shift 2
      ;;
    --public-ed-key)
      SPARKLE_PUBLIC_ED_KEY="$2"
      shift 2
      ;;
    --signing-identity)
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --min-system-version)
      MIN_SYSTEM_VERSION="$2"
      shift 2
      ;;
    --no-sign)
      SIGN_APP=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$VERSION" ]] || fail "--version is required"
[[ -n "$BUILD_NUMBER" ]] || fail "--build is required"
[[ -n "$APPCAST_URL" ]] || fail "--appcast-url or APPCAST_URL is required"
[[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || fail "--public-ed-key or SPARKLE_PUBLIC_ED_KEY is required"

require_tool swift
require_tool ditto
require_tool install_name_tool
require_tool otool
require_tool /usr/libexec/PlistBuddy

ICON_PATH="$ROOT_DIR/Resources/AppIcon.icns"
INFO_TEMPLATE="$ROOT_DIR/Packaging/Info.plist.template"
ENTITLEMENTS_PATH="$ROOT_DIR/Packaging/Release.entitlements"
PRODUCTS_DIR="$ROOT_DIR/.build/apple/Products/Release"
BINARY_PATH="$PRODUCTS_DIR/$APP_EXECUTABLE"
SPARKLE_FRAMEWORK_PATH="$PRODUCTS_DIR/Frameworks/Sparkle.framework"
APP_BUNDLE_PATH="$OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
APP_BINARY_PATH="$APP_CONTENTS_PATH/MacOS/$APP_EXECUTABLE"
INFO_PLIST_PATH="$APP_CONTENTS_PATH/Info.plist"
FRAMEWORKS_PATH="$APP_CONTENTS_PATH/Frameworks"
RESOURCES_PATH="$APP_CONTENTS_PATH/Resources"

if [[ ! -f "$ICON_PATH" ]]; then
  log "Generating app icon"
  swift "$ROOT_DIR/scripts/generate_app_icon.swift" "$ICON_PATH"
fi

log "Building universal release binary"
swift build -c release --arch arm64 --arch x86_64

[[ -f "$BINARY_PATH" ]] || fail "Release binary not found at $BINARY_PATH"
[[ -d "$SPARKLE_FRAMEWORK_PATH" ]] || fail "Sparkle framework not found at $SPARKLE_FRAMEWORK_PATH"

log "Assembling app bundle"
rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$APP_CONTENTS_PATH/MacOS" "$FRAMEWORKS_PATH" "$RESOURCES_PATH"
cp "$INFO_TEMPLATE" "$INFO_PLIST_PATH"
ditto "$BINARY_PATH" "$APP_BINARY_PATH"
ditto "$SPARKLE_FRAMEWORK_PATH" "$FRAMEWORKS_PATH/Sparkle.framework"
cp "$ICON_PATH" "$RESOURCES_PATH/AppIcon.icns"

if ! otool -l "$APP_BINARY_PATH" | grep -q '@executable_path/../Frameworks'; then
  log "Adding Frameworks rpath to app binary"
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BINARY_PATH"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_EXECUTABLE" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_SYSTEM_VERSION" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$INFO_PLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST_PATH"
plutil -lint "$INFO_PLIST_PATH" >/dev/null

if [[ $SIGN_APP -eq 1 && -n "$SIGNING_IDENTITY" ]]; then
  log "Codesigning Sparkle helpers and host app"
  SPARKLE_EMBEDDED_PATH="$FRAMEWORKS_PATH/Sparkle.framework"
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$SPARKLE_EMBEDDED_PATH/Versions/B/Autoupdate"
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$SPARKLE_EMBEDDED_PATH/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$SPARKLE_EMBEDDED_PATH/Versions/B/XPCServices/Installer.xpc"
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$SPARKLE_EMBEDDED_PATH/Versions/B/Updater.app"
  codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$SPARKLE_EMBEDDED_PATH"
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGNING_IDENTITY" "$APP_BUNDLE_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE_PATH"
else
  log "Skipping codesigning"
fi

log "App bundle ready at $APP_BUNDLE_PATH"
