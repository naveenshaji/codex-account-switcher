#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_keys"

if [[ ! -x "$TOOL" ]]; then
  echo "error: Sparkle generate_keys tool not found; run swift package resolve first" >&2
  exit 1
fi

exec "$TOOL" "$@"
