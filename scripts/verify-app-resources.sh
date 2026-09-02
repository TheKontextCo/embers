#!/usr/bin/env bash
# Verify release identity, localization, icon, and privacy resources before signing.
set -euo pipefail

APP="${1:-}"
if [[ "$APP" == "--help" || "$APP" == "-h" ]]; then
  echo "usage: scripts/verify-app-resources.sh path/to/embers.app"
  exit 0
fi
[[ -n "$APP" ]] || { echo "usage: scripts/verify-app-resources.sh path/to/embers.app" >&2; exit 64; }

INFO="$APP/Contents/Info.plist"
RESOURCES="$APP/Contents/Resources"
ICON="$RESOURCES/AppIcon.icns"
PRIVACY="$RESOURCES/PrivacyInfo.xcprivacy"
LOCALIZABLE="$RESOURCES/en.lproj/Localizable.strings"
INFO_STRINGS="$RESOURCES/en.lproj/InfoPlist.strings"

for file in "$INFO" "$ICON" "$PRIVACY" "$LOCALIZABLE" "$INFO_STRINGS"; do
  [[ -f "$file" ]] || { echo "Missing required app resource: $file" >&2; exit 66; }
done

plutil -lint "$INFO" "$PRIVACY" "$LOCALIZABLE" "$INFO_STRINGS" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO")" == "Embers" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO")" == "AppIcon" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :EmbersProjectURL' "$INFO")" == "https://github.com/TheKontextCo/embers" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :EmbersIssueURL' "$INFO")" == "https://github.com/TheKontextCo/embers/issues/new" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :EmbersSecurityURL' "$INFO")" == "https://github.com/TheKontextCo/embers/security" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$PRIVACY")" == "false" ]]
/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes' "$PRIVACY" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' "$PRIVACY" >/dev/null
grep -q '"about.title"' "$LOCALIZABLE"
grep -q '"NSMicrophoneUsageDescription"' "$INFO_STRINGS"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/embers-icon-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
iconutil -c iconset "$ICON" -o "$WORK/AppIcon.iconset"
[[ -f "$WORK/AppIcon.iconset/icon_512x512@2x.png" ]]
echo "✓ verified app identity, privacy manifest, icon, and localization resources"
