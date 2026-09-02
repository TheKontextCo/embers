#!/usr/bin/env bash
# Offline guard for the repository surfaces a new contributor needs before
# cloning, reporting a problem, or proposing a change.
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
SCRIPT_RELATIVE_PATH="${SCRIPT_PATH#"$ROOT/"}"
SENSITIVE_CONTENT_PATTERN='/Users/[^/]+/|/home/[^/]+/|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}'
failures=0

fail() {
  echo "repository readiness: $*" >&2
  failures=$((failures + 1))
}

require_file() {
  local path="$1"
  [[ -f "$ROOT/$path" ]] || fail "missing $path"
}

require_text() {
  local path="$1"
  local pattern="$2"
  local description="$3"
  if [[ ! -f "$ROOT/$path" ]] || ! grep -Eq "$pattern" "$ROOT/$path"; then
    fail "$path must document $description"
  fi
}

has_sensitive_tracked_content() {
  local repository="$1"
  git -C "$repository" grep -IlE "$SENSITIVE_CONTENT_PATTERN" -- \
    ':(exclude)designs/**' \
    ":(exclude)$SCRIPT_RELATIVE_PATH" | grep -q .
}

verify_sensitive_content_detector() {
  local test_repository
  local probe
  test_repository="$(mktemp -d "${TMPDIR:-/tmp}/embers-readiness-detector.XXXXXX")"
  mkdir -p "$test_repository/$(dirname "$SCRIPT_RELATIVE_PATH")"
  git -C "$test_repository" init -q
  cp "$ROOT/$SCRIPT_RELATIVE_PATH" "$test_repository/$SCRIPT_RELATIVE_PATH"
  git -C "$test_repository" add "$SCRIPT_RELATIVE_PATH"

  if has_sensitive_tracked_content "$test_repository"; then
    rm -rf "$test_repository"
    return 1
  fi

  for probe in \
    '/Users/example/project/file.md' \
    '/home/example/project/file.md' \
    'BEGIN OPENSSH PRIVATE KEY' \
    'AKIA1234567890ABCDEF'; do
    printf '%s\n' "$probe" > "$test_repository/probe.txt"
    git -C "$test_repository" add probe.txt
    if ! has_sensitive_tracked_content "$test_repository"; then
      rm -rf "$test_repository"
      return 1
    fi
    git -C "$test_repository" rm --cached -q probe.txt
    rm -f "$test_repository/probe.txt"
  done

  rm -rf "$test_repository"
}

for path in \
  README.md \
  CONTRIBUTING.md \
  CODE_OF_CONDUCT.md \
  SECURITY.md \
  SUPPORT.md \
  docs/KNOWN_LIMITATIONS.md \
  docs/RELEASING.md \
  .github/ISSUE_TEMPLATE/bug_report.yml \
  .github/ISSUE_TEMPLATE/compatibility_report.yml \
  .github/ISSUE_TEMPLATE/feature_request.yml \
  .github/ISSUE_TEMPLATE/config.yml \
  .github/pull_request_template.md \
  .github/workflows/ci.yml; do
  require_file "$path"
done

require_text README.md 'swift test' 'the test command'
require_text README.md './scripts/bundle\.sh debug' 'the signed local bundle command'
require_text README.md 'docs/KNOWN_LIMITATIONS\.md' 'known limitations'
require_text README.md 'SECURITY\.md' 'private security reporting'
require_text README.md 'SUPPORT\.md' 'the support route'
require_text CONTRIBUTING.md './scripts/verify-repository-readiness\.sh' 'the repository-readiness check'
require_text CONTRIBUTING.md './scripts/test-release-scripts\.sh' 'the release-script check used by CI'
require_text docs/RELEASING.md './scripts/release\.sh' 'the release operator command'
require_text .github/workflows/ci.yml 'verify-repository-readiness\.sh' 'the repository-readiness CI gate'
require_text .github/workflows/ci.yml 'runs-on: macos-26' 'the pinned supported macOS runner'
require_text .github/workflows/ci.yml 'swift test' 'the Swift test gate'
require_text .github/workflows/ci.yml 'test-release-scripts\.sh' 'the release-script test gate'
require_text .github/pull_request_template.md 'Testing' 'test evidence'
require_text .github/pull_request_template.md 'Privacy' 'privacy-boundary review'

for ignored in \
  '/.build/' \
  '/build/' \
  '/dist/' \
  '.DS_Store' \
  '/.swiftpm/' \
  '*.xcuserdatad/' \
  '/Config/Signing.local.xcconfig'; do
  if ! grep -Fqx "$ignored" "$ROOT/.gitignore"; then
    fail ".gitignore must contain $ignored"
  fi
done

while IFS= read -r tracked; do
  # A readiness change may remove a previously tracked local file before it is
  # committed; judge the candidate tree rather than the parent commit's index.
  [[ -e "$ROOT/$tracked" ]] || continue
  case "$tracked" in
    .DS_Store|*/.DS_Store|.build/*|build/*|dist/*|.swiftpm/*|*/xcuserdata/*|*.xcuserdatad/*|Config/Signing.local.xcconfig)
      fail "machine-local file is tracked: $tracked"
      ;;
  esac
done < <(git -C "$ROOT" ls-files)

if ! verify_sensitive_content_detector; then
  fail "tracked-content detector failed its self-test"
fi

if has_sensitive_tracked_content "$ROOT"; then
  fail "tracked contributor inputs contain an absolute home path, private key, or AWS access-key marker"
fi

if [[ -d "$ROOT/Sources/embers/Resources/SampleVault" ]]; then
  if find "$ROOT/Sources/embers/Resources/SampleVault" -type l -print -quit | grep -q .; then
    fail "the bundled sample vault must not contain symlinks"
  fi
  if git -C "$ROOT" grep -IlE '/Users/[^/]+/|/home/[^/]+/' -- 'Sources/embers/Resources/SampleVault/**' | grep -q .; then
    fail "the bundled sample vault contains a machine-specific path"
  fi
else
  fail "missing deterministic bundled sample vault"
fi

if (( failures > 0 )); then
  echo "repository readiness: $failures failure(s)" >&2
  exit 1
fi

echo "✓ repository contributor surfaces and tracked inputs are ready"
