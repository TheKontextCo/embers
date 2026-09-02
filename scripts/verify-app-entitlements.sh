#!/usr/bin/env bash
# Verify the narrowly scoped capabilities Embers needs when distributed with
# App Sandbox. This runs after signing so it checks the entitlement blob that
# Gatekeeper and the sandbox will actually enforce.
set -euo pipefail

APP="${1:-}"

if [[ "$APP" == "--help" || "$APP" == "-h" ]]; then
  echo "usage: scripts/verify-app-entitlements.sh APP"
  exit 0
fi
if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "Expected an app bundle with Contents: $APP" >&2
  exit 64
fi

ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/embers-entitlements.XXXXXX.plist")"
cleanup() { rm -f "$ENTITLEMENTS"; }
trap cleanup EXIT
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null

require_true() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    echo "Missing required true entitlement: $key" >&2
    exit 65
  fi
}

require_true com.apple.security.app-sandbox
require_true com.apple.security.files.user-selected.read-write
require_true com.apple.security.device.audio-input
require_true com.apple.security.network.client

# Do not let future changes silently broaden filesystem reach. User-selected
# folders are represented above; all other standard and temporary filesystem
# exceptions are intentionally rejected.
for forbidden in \
  com.apple.security.files.all \
  com.apple.security.files.downloads.read-only \
  com.apple.security.files.downloads.read-write \
  com.apple.security.files.documents.read-only \
  com.apple.security.files.documents.read-write \
  com.apple.security.files.pictures.read-only \
  com.apple.security.files.pictures.read-write \
  com.apple.security.files.music.read-only \
  com.apple.security.files.music.read-write \
  com.apple.security.files.movies.read-only \
  com.apple.security.files.movies.read-write \
  com.apple.security.files.removable-media.read-only \
  com.apple.security.files.removable-media.read-write \
  com.apple.security.temporary-exception.files.absolute-path.read-only \
  com.apple.security.temporary-exception.files.absolute-path.read-write \
  com.apple.security.temporary-exception.files.home-relative-path.read-only \
  com.apple.security.temporary-exception.files.home-relative-path.read-write; do
  if /usr/libexec/PlistBuddy -c "Print :$forbidden" "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "Forbidden broad filesystem entitlement: $forbidden" >&2
    exit 65
  fi
done

# Hardened Runtime exceptions weaken code-signing protections. Embers and its
# FoundationModels integration use only Apple frameworks and do not require
# executable-memory allocation, injected libraries, DYLD overrides, debugging,
# or a development task port. Keep this denylist explicit so a future signing
# change cannot silently widen the shipped app's runtime attack surface.
for forbidden in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-executable-page-protection \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.cs.allow-dyld-environment-variables \
  com.apple.security.cs.debugger \
  com.apple.security.get-task-allow; do
  if /usr/libexec/PlistBuddy -c "Print :$forbidden" "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "Forbidden Hardened Runtime exception: $forbidden" >&2
    exit 65
  fi
done

echo "✓ verified minimized sandbox, user-selected folder, audio-input, and network-client entitlements"
