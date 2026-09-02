#!/usr/bin/env bash
# Fast offline guardrails for release automation. Full signing/notarization is
# intentionally exercised only with real operator credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for script in bundle.sh distribution-support.sh verify-clean-worktree.sh verify-distribution-binaries.sh verify-app-entitlements.sh verify-app-resources.sh generate-app-icon.sh release.sh verify-release.sh; do
  bash -n "$ROOT/scripts/$script"
done

"$ROOT/scripts/release.sh" --help >/dev/null
"$ROOT/scripts/verify-release.sh" --help >/dev/null
"$ROOT/scripts/verify-distribution-binaries.sh" --help >/dev/null
"$ROOT/scripts/verify-app-entitlements.sh" --help >/dev/null
"$ROOT/scripts/verify-app-resources.sh" --help >/dev/null
source "$ROOT/scripts/distribution-support.sh"
[[ "$EMBERS_MINIMUM_MACOS" == "26.0" ]]
[[ "${EMBERS_REQUIRED_ARCHITECTURES[*]}" == "arm64" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")" == "$EMBERS_MINIMUM_MACOS" ]]
grep -q 'platforms: \[\.macOS(\.v26)\]' "$ROOT/Package.swift"
grep -q 'macOS: "26.0"' "$ROOT/project.yml"
grep -q 'ARCHS: arm64' "$ROOT/project.yml"
grep -q 'EMBERS_SIGNING_IDENTITY=-' "$ROOT/scripts/release.sh"
grep -q 'codesign --remove-signature.*Contents/MacOS/embers' "$ROOT/scripts/bundle.sh"
grep -q 'Developer ID codesign with secure timestamp' "$ROOT/scripts/release.sh"
grep -q 'verify-distribution-binaries.sh' "$ROOT/scripts/release.sh"
grep -q 'verify-distribution-binaries.sh' "$ROOT/scripts/verify-release.sh"
grep -q 'EMBERS_REQUIRED_ARCHITECTURES' "$ROOT/scripts/bundle.sh"
grep -q 'EMBERS_SWIFT_SCRATCH_PATH' "$ROOT/scripts/bundle.sh"
grep -q 'EMBERS_REJECT_PERSONAL_BUILD_PATHS=1' "$ROOT/scripts/release.sh"
grep -q 'Personal home-directory path embedded in release binary' "$ROOT/scripts/verify-distribution-binaries.sh"
grep -q 'EMBERS_REJECT_PERSONAL_BUILD_PATHS=1' "$ROOT/scripts/verify-release.sh"
grep -q -- '--timestamp' "$ROOT/scripts/bundle.sh"
grep -q 'Timestamp=' "$ROOT/scripts/verify-release.sh"
grep -q 'notarytool submit' "$ROOT/scripts/release.sh"
grep -q 'stapler staple' "$ROOT/scripts/release.sh"
grep -q 'hdiutil create' "$ROOT/scripts/release.sh"
grep -q 'Applications' "$ROOT/scripts/release.sh"
grep -q 'codesign.*--timestamp.*DMG' "$ROOT/scripts/release.sh"
grep -q 'notarytool submit.*DMG' "$ROOT/scripts/release.sh"
grep -q 'stapler staple.*DMG' "$ROOT/scripts/release.sh"
grep -q 'spctl --assess' "$ROOT/scripts/verify-release.sh"
grep -q 'updatePolicy.: .manual.' "$ROOT/scripts/release.sh"
grep -q 'verify-clean-worktree.sh' "$ROOT/scripts/release.sh"
grep -q 'RELEASE_VERSION:.*inputs.version' "$ROOT/.github/workflows/release.yml"
grep -q 'release.sh.*RELEASE_VERSION.*RELEASE_BUILD' "$ROOT/.github/workflows/release.yml"
! grep -q "release.sh.*inputs.version" "$ROOT/.github/workflows/release.yml"
grep -q 'name: embers-.*-macos-dmg' "$ROOT/.github/workflows/release.yml"
grep -q 'com.apple.security.app-sandbox' "$ROOT/Resources/embers.entitlements"
grep -q 'com.apple.security.files.user-selected.read-write' "$ROOT/Resources/embers.entitlements"
grep -q 'com.apple.security.device.audio-input' "$ROOT/Resources/embers.entitlements"
grep -q 'com.apple.security.network.client' "$ROOT/Resources/embers.entitlements"
! grep -q 'com.apple.security.cs.allow-jit' "$ROOT/Resources/embers.entitlements"
grep -q 'com.apple.security.cs.allow-unsigned-executable-memory' "$ROOT/scripts/verify-app-entitlements.sh"
grep -q 'com.apple.security.cs.disable-executable-page-protection' "$ROOT/scripts/verify-app-entitlements.sh"
grep -q 'com.apple.security.cs.disable-library-validation' "$ROOT/scripts/verify-app-entitlements.sh"
grep -q 'com.apple.security.cs.allow-dyld-environment-variables' "$ROOT/scripts/verify-app-entitlements.sh"
grep -q 'com.apple.security.get-task-allow' "$ROOT/scripts/verify-app-entitlements.sh"
grep -q 'verify-app-entitlements.sh' "$ROOT/scripts/bundle.sh"
grep -q 'verify-app-entitlements.sh' "$ROOT/scripts/verify-release.sh"
grep -q 'PrivacyInfo.xcprivacy' "$ROOT/scripts/bundle.sh"
grep -q 'generate-app-icon.sh' "$ROOT/scripts/bundle.sh"
grep -q 'verify-app-resources.sh' "$ROOT/scripts/bundle.sh"
grep -q 'verify-app-resources.sh' "$ROOT/scripts/verify-release.sh"
grep -q 'hdiutil attach' "$ROOT/scripts/verify-release.sh"
grep -q 'hdiutil detach' "$ROOT/scripts/verify-release.sh"
grep -q 'hdiutil verify' "$ROOT/scripts/verify-release.sh"
grep -q 'Format raw.*UDZO' "$ROOT/scripts/verify-release.sh"
grep -q 'VolumeName raw' "$ROOT/scripts/verify-release.sh"
grep -q 'MOUNTED_APP' "$ROOT/scripts/verify-release.sh"
grep -q 'TOP_LEVEL_ENTRIES' "$ROOT/scripts/verify-release.sh"
grep -q -- '-L.*Applications' "$ROOT/scripts/verify-release.sh"
grep -q 'context:primary-signature' "$ROOT/scripts/verify-release.sh"
grep -q 'stapler validate.*DMG' "$ROOT/scripts/verify-release.sh"
grep -q 'EXPECTED_SOURCE_COMMIT' "$ROOT/scripts/verify-release.sh"
grep -q 'EXPECTED_NOTARIZED' "$ROOT/scripts/verify-release.sh"
grep -q 'SIGNED_MANIFEST' "$ROOT/scripts/verify-release.sh"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$ROOT/Resources/Info.plist")" == "Embers" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/Resources/Info.plist")" == "AppIcon" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :EmbersProjectURL' "$ROOT/Resources/Info.plist")" == "https://github.com/TheKontextCo/embers" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :EmbersIssueURL' "$ROOT/Resources/Info.plist")" == "https://github.com/TheKontextCo/embers/issues/new" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :EmbersSecurityURL' "$ROOT/Resources/Info.plist")" == "https://github.com/TheKontextCo/embers/security" ]]
plutil -lint "$ROOT/Resources/PrivacyInfo.xcprivacy" "$ROOT/Sources/embers/Resources/en.lproj/Localizable.strings" "$ROOT/Resources/en.lproj/InfoPlist.strings" >/dev/null
grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' "$ROOT/Resources/PrivacyInfo.xcprivacy"
grep -q 'NSPrivacyAccessedAPICategoryUserDefaults' "$ROOT/Resources/PrivacyInfo.xcprivacy"
[[ "$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$ROOT/Resources/PrivacyInfo.xcprivacy")" == "[]" ]]
grep -q '"about.title"' "$ROOT/Sources/embers/Resources/en.lproj/Localizable.strings"
grep -q '"NSMicrophoneUsageDescription"' "$ROOT/Resources/en.lproj/InfoPlist.strings"

CLEAN_TEST_REPO="$(mktemp -d "${TMPDIR:-/tmp}/embers-clean-tree-test.XXXXXX")"
cleanup() { rm -rf "$CLEAN_TEST_REPO"; }
trap cleanup EXIT
VALID_JSON="$CLEAN_TEST_REPO/valid.json"
INVALID_JSON="$CLEAN_TEST_REPO/invalid.json"
printf '%s\n' '{"schemaVersion":1,"notarized":true}' > "$VALID_JSON"
printf '%s\n' '{"schemaVersion":' > "$INVALID_JSON"
embers_validate_json "$VALID_JSON"
if embers_validate_json "$INVALID_JSON" >/dev/null 2>&1; then
  echo "JSON validator accepted malformed release metadata." >&2
  exit 1
fi
rm "$VALID_JSON" "$INVALID_JSON"
git -C "$CLEAN_TEST_REPO" init -q
touch "$CLEAN_TEST_REPO/tracked"
git -C "$CLEAN_TEST_REPO" add tracked
git -C "$CLEAN_TEST_REPO" -c user.name=Embers -c user.email=release-test@example.invalid commit -qm initial
"$ROOT/scripts/verify-clean-worktree.sh" "$CLEAN_TEST_REPO" >/dev/null
touch "$CLEAN_TEST_REPO/untracked.swift"
if "$ROOT/scripts/verify-clean-worktree.sh" "$CLEAN_TEST_REPO" >/dev/null 2>&1; then
  echo "Clean-tree verifier accepted an untracked source file." >&2
  exit 1
fi

SIGNED_FIXTURE="$CLEAN_TEST_REPO/signed-fixture"
cp /usr/bin/true "$SIGNED_FIXTURE"
codesign --force --sign - "$SIGNED_FIXTURE" >/dev/null 2>&1
[[ -n "$(embers_code_hash "$SIGNED_FIXTURE")" ]]
echo "✓ release script checks passed"
