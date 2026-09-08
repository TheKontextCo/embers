#!/usr/bin/env bash
# Offline, version-pinned complexity gate. Installing the tool is explicit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFTLINT="${EMBERS_SWIFTLINT:-swiftlint}"
if ! command -v "$SWIFTLINT" >/dev/null 2>&1; then
  echo 'SwiftLint 0.65.1 is required; see docs/COMPLEXITY.md.' >&2
  exit 69
fi
if [[ "$("$SWIFTLINT" version)" != "0.65.1" ]]; then
  echo 'Expected SwiftLint 0.65.1; set EMBERS_SWIFTLINT to that binary.' >&2
  exit 65
fi
cd "$ROOT"
if [[ "$#" -eq 0 ]]; then
  set -- Sources Tests
fi
exec "$SWIFTLINT" lint --no-cache --config "$ROOT/.swiftlint.yml" --quiet "$@"
