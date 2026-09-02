#!/usr/bin/env bash
# Verify every Mach-O payload in an Embers app is Apple-silicon-only and uses
# the supported deployment target. This deliberately scans frameworks, helper
# tools, and plug-ins as well as the main executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/distribution-support.sh"
APP="${1:-}"

if [[ "$APP" == "--help" || "$APP" == "-h" ]]; then
  echo "usage: scripts/verify-distribution-binaries.sh APP"
  exit 0
fi
if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "Expected an app bundle with Contents: $APP" >&2
  exit 64
fi

INFO_MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
if [[ "$INFO_MINIMUM_MACOS" != "$EMBERS_MINIMUM_MACOS" ]]; then
  echo "LSMinimumSystemVersion is $INFO_MINIMUM_MACOS; expected $EMBERS_MINIMUM_MACOS." >&2
  exit 65
fi

checked=0
while IFS= read -r -d '' candidate; do
  if ! file -b "$candidate" | grep -q 'Mach-O'; then
    continue
  fi

  architectures="$(lipo -archs "$candidate")"
  for required in "${EMBERS_REQUIRED_ARCHITECTURES[@]}"; do
    if [[ " $architectures " != *" $required "* ]]; then
      echo "Missing $required slice: $candidate ($architectures)" >&2
      exit 65
    fi
  done

  for architecture in $architectures; do
    if [[ " ${EMBERS_REQUIRED_ARCHITECTURES[*]} " != *" $architecture "* ]]; then
      echo "Unsupported $architecture slice: $candidate ($architectures)" >&2
      exit 65
    fi
  done

  if [[ "${EMBERS_REJECT_PERSONAL_BUILD_PATHS:-0}" == "1" ]] && \
      strings -a "$candidate" | grep -Eq '/(Users|home)/[^/[:space:]]+/'; then
    echo "Personal home-directory path embedded in release binary: $candidate" >&2
    exit 65
  fi

  # Require every advertised deployment target to match the bundle's public
  # support floor; recognize current and legacy Mach-O command spellings.
  deployment_targets="$(otool -l "$candidate" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build = 1; next }
    build && $1 == "minos" { print $2; build = 0; next }
    $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { legacy = 1; next }
    legacy && $1 == "version" { print $2; legacy = 0 }
  ')"
  deployment_target_count=0
  while IFS= read -r minos; do
    [[ -n "$minos" ]] || continue
    deployment_target_count=$((deployment_target_count + 1))
    if [[ "$minos" != "$EMBERS_MINIMUM_MACOS" ]]; then
      echo "Unexpected macOS deployment target $minos: $candidate" >&2
      exit 65
    fi
  done <<< "$deployment_targets"
  if [[ "$deployment_target_count" -ne "${#EMBERS_REQUIRED_ARCHITECTURES[@]}" ]]; then
    echo "Expected ${#EMBERS_REQUIRED_ARCHITECTURES[@]} deployment targets: $candidate" >&2
    exit 65
  fi
  checked=$((checked + 1))
done < <(find "$APP/Contents" -type f -print0)

if [[ "$checked" -eq 0 ]]; then
  echo "No Mach-O payloads found in $APP." >&2
  exit 65
fi

echo "✓ verified $checked Mach-O payload(s): ${EMBERS_REQUIRED_ARCHITECTURES[*]} only, macOS $EMBERS_MINIMUM_MACOS+"
