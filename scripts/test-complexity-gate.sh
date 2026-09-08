#!/usr/bin/env bash
# Exercise the real analyzer and wrapper at the ceiling, not a regex approximation.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$(mktemp -d "${TMPDIR:-/tmp}/embers-complexity-probe.XXXXXX")"
trap 'rm -rf "$PROBE"' EXIT
for score in 20 21; do
  awk -v score="$score" 'BEGIN {
    print "func probe(_ values: [Bool]) {"
    for (i = 0; i < score; i++) print "    if values[" i "] { print(" i ") }"
    print "}"
  }' > "$PROBE/Score$score.swift"
done
"$ROOT/scripts/verify-complexity.sh" "$PROBE/Score20.swift" > "$PROBE/pass.log" 2>&1
if "$ROOT/scripts/verify-complexity.sh" "$PROBE/Score21.swift" > "$PROBE/fail.log" 2>&1; then
  echo 'Complexity 21 unexpectedly passed.' >&2
  exit 1
fi
grep -q 'currently complexity is 20' "$PROBE/pass.log"
grep -q 'currently complexity is 21' "$PROBE/fail.log"
echo 'Complexity boundary verified: 20 passes, 21 fails.'
