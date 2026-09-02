#!/usr/bin/env bash
# Verify a release bundle and its adjacent integrity metadata without network I/O.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/distribution-support.sh"

APP="${1:-}"
DMG="${2:-}"
CHECKSUM="${3:-}"
METADATA="${4:-}"

if [[ "$APP" == "--help" || "$APP" == "-h" ]]; then
  echo "usage: scripts/verify-release.sh APP DMG DMG.sha256 release.json"
  exit 0
fi
if [[ -z "$APP" || -z "$DMG" || -z "$CHECKSUM" || -z "$METADATA" ]]; then
  echo "usage: scripts/verify-release.sh APP DMG DMG.sha256 release.json" >&2
  exit 64
fi
for file in "$APP" "$DMG" "$CHECKSUM" "$METADATA"; do
  [[ -e "$file" ]] || { echo "Missing release input: $file" >&2; exit 66; }
done
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
CHECKSUM="$(cd "$(dirname "$CHECKSUM")" && pwd)/$(basename "$CHECKSUM")"
METADATA="$(cd "$(dirname "$METADATA")" && pwd)/$(basename "$METADATA")"
for command in codesign diskutil hdiutil lipo plutil readlink shasum spctl xcrun; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 69
  }
done

read -r CHECKSUM_HASH CHECKSUM_NAME CHECKSUM_EXTRA < "$CHECKSUM"
if [[ ! "$CHECKSUM_HASH" =~ ^[0-9a-fA-F]{64}$ || "$CHECKSUM_NAME" != "$(basename "$DMG")" || -n "${CHECKSUM_EXTRA:-}" ]]; then
  echo "Checksum file must contain exactly the SHA-256 and basename of the supplied DMG." >&2
  exit 65
fi
(cd "$(dirname "$DMG")" && shasum -a 256 -c "$CHECKSUM")

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/embers-release-verify.XXXXXX")"
MOUNT_POINT="$VERIFY_DIR/volume"
IMAGE_INFO="$VERIFY_DIR/image-info.plist"
VOLUME_INFO="$VERIFY_DIR/volume-info.plist"
DMG_ATTACHED=0
cleanup() {
  if [[ "$DMG_ATTACHED" == 1 ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT
mkdir -p "$MOUNT_POINT"

verify_dmg() {
  hdiutil verify "$DMG" >/dev/null
  hdiutil imageinfo -plist "$DMG" > "$IMAGE_INFO"
  if [[ "$(plutil -extract Format raw -o - "$IMAGE_INFO" 2>/dev/null || true)" != "UDZO" || "$(plutil -extract Properties.Encrypted raw -o - "$IMAGE_INFO" 2>/dev/null || true)" != "false" ]]; then
    echo "DMG must be an unencrypted, compressed read-only UDIF image." >&2
    exit 65
  fi
  codesign --verify --strict --verbose=4 "$DMG"
  local signature_details
  signature_details="$(codesign -dv --verbose=4 "$DMG" 2>&1)"
  [[ "$signature_details" == *"Authority=Developer ID Application:"* ]] || {
    echo "DMG is not signed by a Developer ID Application certificate." >&2
    exit 65
  }
  [[ "$signature_details" == *"Timestamp="* ]] || {
    echo "DMG signature is missing a secure timestamp." >&2
    exit 65
  }
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
}

verify_dmg
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=1
diskutil info -plist "$MOUNT_POINT" > "$VOLUME_INFO"
if [[ "$(plutil -extract VolumeName raw -o - "$VOLUME_INFO" 2>/dev/null || true)" != "Embers" ]]; then
  echo "DMG volume name must be Embers." >&2
  exit 65
fi
MOUNTED_APP="$MOUNT_POINT/Embers.app"
shopt -s nullglob dotglob
TOP_LEVEL_ENTRIES=("$MOUNT_POINT"/*)
shopt -u nullglob dotglob
if [[ "${#TOP_LEVEL_ENTRIES[@]}" -ne 2 || ! -d "$MOUNTED_APP/Contents" || ! -L "$MOUNT_POINT/Applications" ]]; then
  echo "DMG must contain only Embers.app and the Applications link." >&2
  exit 65
fi
if [[ "$(readlink "$MOUNT_POINT/Applications")" != "/Applications" ]]; then
  echo "DMG Applications link must target /Applications." >&2
  exit 65
fi

verify_app() {
  local candidate="$1"
  plutil -lint "$candidate/Contents/Info.plist" >/dev/null
  "$ROOT/scripts/verify-app-resources.sh" "$candidate"
  EMBERS_REJECT_PERSONAL_BUILD_PATHS=1 \
    "$ROOT/scripts/verify-distribution-binaries.sh" "$candidate"
  "$ROOT/scripts/verify-app-entitlements.sh" "$candidate"
  codesign --verify --deep --strict --verbose=4 "$candidate"
  local signature_details
  signature_details="$(codesign -dv --verbose=4 "$candidate" 2>&1)"
  [[ "$signature_details" == *"Authority=Developer ID Application:"* ]] || {
    echo "App is not signed by a Developer ID Application certificate: $candidate" >&2
    exit 65
  }
  [[ "$signature_details" == *"Timestamp="* ]] || {
    echo "App signature is missing a secure timestamp: $candidate" >&2
    exit 65
  }
  xcrun stapler validate "$candidate"
  spctl --assess --type execute --verbose=4 "$candidate"
}

embers_validate_json "$METADATA"
verify_app "$APP"
verify_app "$MOUNTED_APP"

if [[ -z "$(embers_code_hash "$APP")" || "$(embers_code_hash "$APP")" != "$(embers_code_hash "$MOUNTED_APP")" ]]; then
  echo "The adjacent app does not match the signed app inside the DMG." >&2
  exit 65
fi

EXPECTED_ARTIFACT_TYPE="$(plutil -extract artifactType raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_DMG="$(plutil -extract artifact raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_VOLUME_NAME="$(plutil -extract volumeName raw -o - "$METADATA" 2>/dev/null || true)"
if [[ "$EXPECTED_ARTIFACT_TYPE" != "diskImage" || "$EXPECTED_DMG" != "$(basename "$DMG")" || "$EXPECTED_VOLUME_NAME" != "Embers" ]]; then
  echo "release.json disk-image metadata does not match supplied DMG." >&2
  exit 65
fi
EXPECTED_CHECKSUM="$(plutil -extract checksum raw -o - "$METADATA" 2>/dev/null || true)"
if [[ "$EXPECTED_CHECKSUM" != "$(basename "$CHECKSUM")" ]]; then
  echo "release.json checksum does not match supplied checksum file." >&2
  exit 65
fi
EXPECTED_ARCHITECTURES="$(plutil -extract architectures raw -o - "$METADATA" 2>/dev/null || true)"
MOUNTED_ARCHITECTURES="$(lipo -archs "$MOUNTED_APP/Contents/MacOS/embers")"
if [[ "$EXPECTED_ARCHITECTURES" != "$MOUNTED_ARCHITECTURES" ]]; then
  echo "release.json architectures do not match the app in the DMG." >&2
  exit 65
fi
for required in "${EMBERS_REQUIRED_ARCHITECTURES[@]}"; do
  if [[ " $EXPECTED_ARCHITECTURES " != *" $required "* ]]; then
    echo "release.json is missing required $required architecture." >&2
    exit 65
  fi
done
EXPECTED_MINIMUM_MACOS="$(plutil -extract minimumMacOS raw -o - "$METADATA" 2>/dev/null || true)"
APP_MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$MOUNTED_APP/Contents/Info.plist")"
if [[ "$EXPECTED_MINIMUM_MACOS" != "$EMBERS_MINIMUM_MACOS" || "$EXPECTED_MINIMUM_MACOS" != "$APP_MINIMUM_MACOS" ]]; then
  echo "release.json minimumMacOS must be $EMBERS_MINIMUM_MACOS." >&2
  exit 65
fi

EXPECTED_VERSION="$(plutil -extract version raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_BUILD="$(plutil -extract build raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_BUNDLE_ID="$(plutil -extract bundleIdentifier raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_SOURCE_COMMIT="$(plutil -extract sourceCommit raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_NOTARIZED="$(plutil -extract notarized raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_MANIFEST="$(plutil -extract signedManifest raw -o - "$METADATA" 2>/dev/null || true)"
EXPECTED_UPDATE_POLICY="$(plutil -extract updatePolicy raw -o - "$METADATA" 2>/dev/null || true)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MOUNTED_APP/Contents/Info.plist")"
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MOUNTED_APP/Contents/Info.plist")"
CURRENT_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

if [[ "$EXPECTED_VERSION" != "$APP_VERSION" || "$EXPECTED_BUILD" != "$APP_BUILD" || "$EXPECTED_BUNDLE_ID" != "$APP_BUNDLE_ID" ]]; then
  echo "release.json identity does not match the archived app." >&2
  exit 65
fi
if [[ "$EXPECTED_SOURCE_COMMIT" != "$CURRENT_COMMIT" || "$EXPECTED_NOTARIZED" != "true" || "$EXPECTED_UPDATE_POLICY" != "manual" ]]; then
  echo "release.json provenance or notarization state is invalid for this checkout." >&2
  exit 65
fi
if [[ "$EXPECTED_MANIFEST" != "update-manifest.json" ]]; then
  echo "release.json signedManifest must be update-manifest.json." >&2
  exit 65
fi

SIGNED_MANIFEST="$MOUNTED_APP/Contents/Resources/$EXPECTED_MANIFEST"
embers_validate_json "$SIGNED_MANIFEST"
for key in version build bundleIdentifier minimumMacOS sourceCommit updatePolicy; do
  metadata_value="$(plutil -extract "$key" raw -o - "$METADATA" 2>/dev/null || true)"
  manifest_value="$(plutil -extract "$key" raw -o - "$SIGNED_MANIFEST" 2>/dev/null || true)"
  if [[ "$metadata_value" != "$manifest_value" ]]; then
    echo "Embedded signed manifest $key does not match release.json." >&2
    exit 65
  fi
done
hdiutil detach "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=0
echo "✓ verified signed, stapled DMG release artifact"
