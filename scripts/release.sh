#!/usr/bin/env bash
# Create a locally distributable, signed and notarized Embers release.
#
# This script never publishes a release and the app it produces contains no
# updater or network checker. Credentials are supplied only at invocation time
# through a Developer ID identity and a notarytool keychain profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/distribution-support.sh"
VERSION="${1:-}"
BUILD="${2:-}"
RELEASE_DIR="${EMBERS_RELEASE_DIR:-$ROOT/build/release}"
IDENTITY="${EMBERS_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${EMBERS_NOTARY_KEYCHAIN_PROFILE:-}"

usage() {
  cat <<'EOF'
usage: scripts/release.sh VERSION BUILD

Required environment:
  EMBERS_SIGNING_IDENTITY            Developer ID Application identity or SHA-1
  EMBERS_NOTARY_KEYCHAIN_PROFILE     notarytool credentials profile in the active keychain

Optional environment:
  EMBERS_RELEASE_DIR                 output directory (default: build/release)
EOF
}

if [[ "$VERSION" == "--help" || "$VERSION" == "-h" ]]; then
  usage
  exit 0
fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}([-.][0-9A-Za-z.-]+)?$ || ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
  usage >&2
  echo "VERSION must be numeric SemVer-like and BUILD must be a positive integer." >&2
  exit 64
fi
if [[ -z "$IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  usage >&2
  echo "Refusing to create an unsigned or unnotarized public-release artifact." >&2
  exit 64
fi
"$ROOT/scripts/verify-clean-worktree.sh" "$ROOT"
if [[ "$(git -C "$ROOT" describe --exact-match --tags HEAD 2>/dev/null || true)" != "v$VERSION" ]]; then
  echo "Refusing to release: HEAD must be tagged v$VERSION." >&2
  exit 65
fi

for command in codesign ditto git hdiutil lipo plutil shasum spctl xcrun; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 69
  }
done

mkdir -p "$RELEASE_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/embers-release.XXXXXX")"
cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

APP="$RELEASE_DIR/embers.app"
DMG="$RELEASE_DIR/embers-$VERSION-macos.dmg"
CHECKSUM="$DMG.sha256"
METADATA="$RELEASE_DIR/release.json"
SIGNED_MANIFEST="$STAGING_DIR/update-manifest.json"
APP_NOTARY_ARCHIVE="$STAGING_DIR/embers-app-notary.zip"
DMG_ROOT="$STAGING_DIR/dmg-root"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"
if [[ "$MINIMUM_MACOS" != "$EMBERS_MINIMUM_MACOS" ]]; then
  echo "Resources/Info.plist minimum macOS must be $EMBERS_MINIMUM_MACOS." >&2
  exit 65
fi

# This file is copied into the app before codesigning. It is intentionally
# checksum-free: the archive checksum is only knowable after signing and
# stapling. The signed manifest provides a versioned update record without
# giving the app an implicit network-update path.
cat > "$SIGNED_MANIFEST" <<EOF
{
  "schemaVersion": 1,
  "version": "$VERSION",
  "build": $BUILD,
  "bundleIdentifier": "$BUNDLE_ID",
  "minimumMacOS": "$MINIMUM_MACOS",
  "sourceCommit": "$COMMIT",
  "updatePolicy": "manual"
}
EOF
embers_validate_json "$SIGNED_MANIFEST"

rm -rf "$APP" "$DMG" "$CHECKSUM" "$METADATA"
echo "▸ build, sign, and verify app"
EMBERS_APP_PATH="$APP" \
EMBERS_APP_VERSION="$VERSION" \
EMBERS_APP_BUILD="$BUILD" \
EMBERS_RELEASE_MANIFEST="$SIGNED_MANIFEST" \
EMBERS_SWIFT_SCRATCH_PATH="$STAGING_DIR/swift-build" \
EMBERS_REJECT_PERSONAL_BUILD_PATHS=1 \
EMBERS_SIGNING_IDENTITY=- \
"$ROOT/scripts/bundle.sh" release

echo "▸ Developer ID codesign with secure timestamp"
codesign --force --deep --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  --entitlements "$ROOT/Resources/embers.entitlements" \
  "$APP"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNATURE_DETAILS" != *"Authority=Developer ID Application:"* ]]; then
  echo "EMBERS_SIGNING_IDENTITY must resolve to a Developer ID Application certificate" >&2
  exit 65
fi
if [[ "$SIGNATURE_DETAILS" != *"Timestamp="* ]]; then
  echo "Developer ID signature is missing a secure timestamp." >&2
  exit 65
fi

echo "▸ verify signed app before notarization"
codesign --verify --deep --strict --verbose=4 "$APP"
"$ROOT/scripts/verify-distribution-binaries.sh" "$APP"

# Notarize the app first so the application carries its own ticket even after
# it is copied out of the disk image. The ZIP is a temporary notary transport,
# never a release artifact.
echo "▸ create app notarization archive"
ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 "$APP" "$APP_NOTARY_ARCHIVE"
echo "▸ notarize app"
xcrun notarytool submit "$APP_NOTARY_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
echo "▸ staple app notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "▸ validate signed, stapled app"
codesign --verify --deep --strict --verbose=4 "$APP"
spctl --assess --type execute --verbose=4 "$APP"

# Keep the disk image deliberately plain: the application and a conventional
# /Applications link are its only top-level entries. No Finder scripting or
# third-party DMG tooling is required.
echo "▸ create drag-to-Applications disk image"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Embers.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname Embers -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

echo "▸ sign and notarize DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=4 "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$CHECKSUM")")
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/embers")"

cat > "$METADATA" <<EOF
{
  "schemaVersion": 1,
  "version": "$VERSION",
  "build": $BUILD,
  "bundleIdentifier": "$BUNDLE_ID",
  "minimumMacOS": "$MINIMUM_MACOS",
  "architectures": "$ARCHITECTURES",
  "sourceCommit": "$COMMIT",
  "artifactType": "diskImage",
  "artifact": "$(basename "$DMG")",
  "checksum": "$(basename "$CHECKSUM")",
  "volumeName": "Embers",
  "signedManifest": "update-manifest.json",
  "notarized": true,
  "updatePolicy": "manual"
}
EOF
embers_validate_json "$METADATA"

"$ROOT/scripts/verify-release.sh" "$APP" "$DMG" "$CHECKSUM" "$METADATA"
echo "✓ release artifacts are in $RELEASE_DIR"
