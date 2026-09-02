#!/usr/bin/env bash
# Build embers and assemble a runnable .app bundle. Prefer a stable Apple
# Development identity so TCC and Keychain permissions survive rebuilds; fall
# back to ad-hoc signing for contributors without a development certificate.
#
# Public releases use this script to assemble a normalized ad-hoc bundle, then
# scripts/release.sh replaces that signature with Developer ID in a fresh
# process before notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/distribution-support.sh"
CONFIG="${1:-debug}"
APP="${EMBERS_APP_PATH:-$ROOT/build/embers.app}"
SWIFT_SCRATCH_PATH="${EMBERS_SWIFT_SCRATCH_PATH:-}"

if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "usage: $0 [debug|release]" >&2
  exit 64
fi

echo "▸ swift build ($CONFIG)"
ARCH_ARGUMENTS=()
for architecture in "${EMBERS_REQUIRED_ARCHITECTURES[@]}"; do
  ARCH_ARGUMENTS+=(--arch "$architecture")
done
BUILD_ARGUMENTS=(-c "$CONFIG" --package-path "$ROOT" "${ARCH_ARGUMENTS[@]}")
if [[ -n "$SWIFT_SCRATCH_PATH" ]]; then
  BUILD_ARGUMENTS+=(--scratch-path "$SWIFT_SCRATCH_PATH")
fi
swift build "${BUILD_ARGUMENTS[@]}"

BIN="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)/embers"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/embers"
# SwiftPM emits an ad-hoc signature on the executable. Strip it before signing
# the assembled bundle so codesign does not leave a stale inner CodeDirectory.
codesign --remove-signature "$APP/Contents/MacOS/embers"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$ROOT/scripts/generate-app-icon.sh" \
  "$ROOT/Resources/AppIcon.svg" \
  "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
mkdir -p "$APP/Contents/Resources/en.lproj"
cp "$ROOT/Resources/en.lproj/InfoPlist.strings" "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
cp "$ROOT/Sources/embers/Resources/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/Localizable.strings"

if [[ -n "${EMBERS_APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $EMBERS_APP_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${EMBERS_APP_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $EMBERS_APP_BUILD" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

"$ROOT/scripts/verify-app-resources.sh" "$APP"

RESOURCE_BUNDLE="$(dirname "$BIN")/embers_embers.bundle"
if [[ -d "$RESOURCE_BUNDLE/SampleVault" ]]; then
  cp -R "$RESOURCE_BUNDLE/SampleVault" "$APP/Contents/Resources/SampleVault"
fi

if [[ -n "${EMBERS_RELEASE_MANIFEST:-}" ]]; then
  if [[ ! -f "$EMBERS_RELEASE_MANIFEST" ]]; then
    echo "EMBERS_RELEASE_MANIFEST does not exist: $EMBERS_RELEASE_MANIFEST" >&2
    exit 66
  fi
  cp "$EMBERS_RELEASE_MANIFEST" "$APP/Contents/Resources/update-manifest.json"
fi

"$ROOT/scripts/verify-distribution-binaries.sh" "$APP"

SIGNING_IDENTITY="${EMBERS_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(git -C "$ROOT" config --get embers.signingIdentity 2>/dev/null || true)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ && !/CSSMERR/ { print $2; exit }')"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "▸ development codesign"
  codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp=none \
    --entitlements "$ROOT/Resources/embers.entitlements" \
    "$APP"
else
  echo "▸ ad-hoc codesign (no Apple Development identity found)"
  codesign --force --deep --sign - \
    --options runtime \
    --entitlements "$ROOT/Resources/embers.entitlements" \
    "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"
fi

"$ROOT/scripts/verify-app-entitlements.sh" "$APP"

echo "✓ built $APP"
