#!/usr/bin/env bash
# Render the original vector source into a deterministic macOS icon. This avoids
# downloaded art and lets every release regenerate the exact icon it ships.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT/Resources/AppIcon.svg}"
OUTPUT="${2:-$ROOT/Resources/AppIcon.icns}"

[[ -f "$SOURCE" ]] || { echo "Missing app icon source: $SOURCE" >&2; exit 66; }
command -v iconutil >/dev/null || { echo "iconutil is required to assemble the app icon." >&2; exit 69; }
command -v swift >/dev/null || { echo "swift is required to render the app icon." >&2; exit 69; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/embers-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

render() {
  local pixels="$1"
  local name="$2"
  swift "$ROOT/scripts/render-app-icon.swift" "$pixels" "$ICONSET/$name"
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "✓ generated $OUTPUT"
