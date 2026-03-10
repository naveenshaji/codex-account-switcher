#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/release/Codex Account Switcher.app"
OUTPUT_DIR="$ROOT_DIR/dist/release"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --app <path>                 Path to the signed .app bundle
  --output-dir <path>          Output directory for notarization artifacts
  --keychain-profile <name>    notarytool keychain profile name
  --apple-id <apple-id>        Apple ID (fallback if not using keychain profile)
  --team-id <team-id>          Apple Developer Team ID
  --app-password <password>    App-specific password for notarytool fallback auth
USAGE
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --keychain-profile)
      NOTARY_KEYCHAIN_PROFILE="$2"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="$2"
      shift 2
      ;;
    --team-id)
      APPLE_TEAM_ID="$2"
      shift 2
      ;;
    --app-password)
      APPLE_APP_PASSWORD="$2"
      shift 2
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

[[ -d "$APP_PATH" ]] || fail "App bundle not found at $APP_PATH"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
command -v ditto >/dev/null 2>&1 || fail "ditto is required"
command -v spctl >/dev/null 2>&1 || fail "spctl is required"

mkdir -p "$OUTPUT_DIR"
APP_BASENAME="$(basename "$APP_PATH" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
SUBMISSION_ZIP="$OUTPUT_DIR/$APP_BASENAME-$VERSION-notary-submission.zip"
FINAL_ZIP="$OUTPUT_DIR/$APP_BASENAME-$VERSION.zip"

log "Preparing notarization upload archive"
rm -f "$SUBMISSION_ZIP" "$FINAL_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

NOTARY_ARGS=()
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_PASSWORD" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  fail "Provide --keychain-profile or the Apple ID credential trio"
fi

log "Submitting build to Apple notarization service"
xcrun notarytool submit "$SUBMISSION_ZIP" --wait "${NOTARY_ARGS[@]}"

log "Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

log "Creating final distributable zip"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
shasum -a 256 "$FINAL_ZIP"

log "Notarized zip ready at $FINAL_ZIP"
