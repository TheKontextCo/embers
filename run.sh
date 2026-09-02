#!/bin/zsh
# embers — build & run.
#
# Why this exists instead of Cmd+R:
#   Xcode's Cmd+R launches the app DIRECTLY under its debugger (lldb/debugserver) as an inactive
#   child process. An inactive accessory (LSUIElement) app's borderless notch panel does NOT receive
#   mouse clicks from the WindowServer — they pass straight through. Launching via `open` runs it as
#   a normal LaunchServices foreground app, which is the only launch where clicks work. Xcode ignores
#   scheme tricks to make it launch via `open`, so we do it here.
#
# Usage:  ./run.sh        (from the project root, or double-click in Finder)

set -e
cd "$(dirname "$0")"
DD="${TMPDIR:-/tmp}/embers-dd"
APP="$DD/Build/Products/Debug/embers.app"

echo "▸ Building…"
xcodebuild -project embers.xcodeproj -scheme embers -configuration Debug -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build \
  >/tmp/embers-build.log 2>&1 || { echo "✗ Build failed:"; grep -E 'error:' /tmp/embers-build.log | head; exit 1; }

echo "▸ Relaunching via open (LaunchServices → clicks work)…"
pkill -f 'MacOS/embers' 2>/dev/null || true
sleep 0.3
open "$APP"
echo "✓ embers launched. (Logs: Console.app → search 'dev.embers')"
