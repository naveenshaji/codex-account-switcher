#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVES_DIR="$ROOT_DIR/dist/appcast"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-}"
RELEASE_NOTES_URL_PREFIX="${RELEASE_NOTES_URL_PREFIX:-}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-}"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-ed25519}"
SPARKLE_BIN_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --archives-dir <path>               Directory containing notarized zip/dmg files
  --download-url-prefix <url>         Public base URL for update archives
  --release-notes-url-prefix <url>    Public base URL for release notes files
  --private-key-file <path>           Private Ed25519 key file for appcast signing
  --keychain-account <account>        Keychain account used by Sparkle generate_appcast (default: ed25519)
USAGE
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archives-dir)
      ARCHIVES_DIR="$2"
      shift 2
      ;;
    --download-url-prefix)
      DOWNLOAD_URL_PREFIX="$2"
      shift 2
      ;;
    --release-notes-url-prefix)
      RELEASE_NOTES_URL_PREFIX="$2"
      shift 2
      ;;
    --private-key-file)
      SPARKLE_PRIVATE_KEY_FILE="$2"
      shift 2
      ;;
    --keychain-account)
      SPARKLE_KEYCHAIN_ACCOUNT="$2"
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

[[ -d "$ARCHIVES_DIR" ]] || fail "Archives directory not found at $ARCHIVES_DIR"
[[ -n "$DOWNLOAD_URL_PREFIX" ]] || fail "--download-url-prefix or DOWNLOAD_URL_PREFIX is required"
[[ -x "$SPARKLE_BIN_DIR/generate_appcast" ]] || fail "Sparkle generate_appcast tool not found; run swift package resolve first"

ARGS=(
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"
)

if [[ -n "$RELEASE_NOTES_URL_PREFIX" ]]; then
  ARGS+=(--release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX")
fi

if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  ARGS+=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
else
  ARGS+=(--account "$SPARKLE_KEYCHAIN_ACCOUNT")
fi

"$SPARKLE_BIN_DIR/generate_appcast" "${ARGS[@]}" "$ARCHIVES_DIR"
