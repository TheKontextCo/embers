#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "provenance check failed: $*" >&2
  exit 1
}

[[ -f THIRD_PARTY_NOTICES.md ]] || fail "THIRD_PARTY_NOTICES.md is missing"
[[ -f provenance/assets.sha256 ]] || fail "provenance/assets.sha256 is missing"

grep -Eq 'DynamicNotchKit' THIRD_PARTY_NOTICES.md || fail "DynamicNotchKit notice is missing"
grep -Eq 'Copyright \(c\) 2025 Kai Azim' THIRD_PARTY_NOTICES.md || fail "DynamicNotchKit copyright notice is missing"
grep -Eq 'MIT License' THIRD_PARTY_NOTICES.md || fail "DynamicNotchKit licence text is missing"

if grep -Eq 'DynamicNotchKit|THIRD_PARTY_NOTICES' Sources/embers/Notch/NotchShape.swift; then
  fail "NotchShape attribution must remain in the central notice, not its source comments"
fi

if git ls-files -s | awk '$1 == 160000 { found = 1 } END { exit !found }'; then
  fail "tracked gitlinks require an explicit, current dependency review"
fi

if grep -Eq 'XCRemoteSwiftPackageReference|https://[^\" ]+\.git' Package.swift embers.xcodeproj/project.pbxproj project.yml; then
  fail "remote Swift package dependency found; review its licence and update THIRD_PARTY_NOTICES.md"
fi

tracked_assets="$(git ls-files | awk 'tolower($0) ~ /\.(icns|svg|png|jpe?g|gif|webp|pdf|mov|mp4|wav|mp3|ttf|otf|woff2?)$/ { print }' | LC_ALL=C sort)"
recorded_assets="$(sed -E 's/^[0-9a-f]{64}  //' provenance/assets.sha256 | LC_ALL=C sort)"
[[ "$tracked_assets" == "$recorded_assets" ]] || fail "tracked release/site assets and provenance/assets.sha256 differ"

shasum -a 256 -c provenance/assets.sha256
echo "third-party notice and asset integrity checks passed"
