#!/usr/bin/env bash
# Release artifacts must be built only from content represented by HEAD.
set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  echo "usage: scripts/verify-clean-worktree.sh REPOSITORY" >&2
  exit 64
fi

if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]]; then
  echo "Refusing to release from a dirty worktree, including untracked files. Commit or stash changes first." >&2
  exit 65
fi

echo "✓ verified clean tracked and untracked release inputs"
