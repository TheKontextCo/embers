# Contributing to Embers

Thank you for helping build a more useful local context layer.

## Before you start

1. Search existing issues and discussions for prior context.
2. For larger changes, open an issue first so we can agree on the problem and acceptance criteria.
3. Keep user content local. Never add a cloud dependency or remote model requirement.

## Development loop

For fast UI development, open `embers.xcodeproj` (not `Package.swift`) and run the
shared `embers` scheme. This builds a native `embers.app`, preserving macOS privacy
permissions across incremental builds. Configure signing once:

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# Replace YOUR_TEAM_ID with the team shown in Xcode → Settings → Accounts.
```

The local signing file is ignored by git. Running the Swift package scheme directly
produces an ad-hoc executable whose microphone, speech, and folder permissions do not
survive rebuilds.

For the full verification loop:

```bash
swift test
./scripts/verify-complexity.sh
./scripts/test-complexity-gate.sh
./scripts/verify-repository-readiness.sh
./scripts/test-release-scripts.sh
git diff --check
./scripts/bundle.sh debug
open build/embers.app
```

Install SwiftLint 0.65.1 as described in [the complexity guide](docs/COMPLEXITY.md).
The checks before bundling are the offline CI-equivalent checks. The bundle and
launch commands provide the signed-app proof required for UI, permissions, and
speech changes. A Developer ID certificate is not required for development;
the bundle script uses an Apple Development identity when available and falls
back to an ad-hoc signature.

Use synthetic or bundled fixture data in tests. Do not commit personal vaults, model outputs, credentials, caches, or absolute user paths.

## Test-first changes

For a bug fix, add a focused regression that fails for the reported behaviour
before changing production code. Keep the test deterministic and use synthetic
inputs. Then run that focused test, the complete `swift test` suite, and the
offline checks above. Voice or peek changes must preserve the cumulative
multi-peek journey covered by `AppStateMultiPeekBaselineTests`.

## Design constraints

- Deterministic code owns identity, evidence, containment, ranking, validation, and retrieval.
- LLMs may propose grounded, evidence-gated enrichment only.
- Preserve both source hierarchy and semantic relations.
- Do not flatten descendant results into their parent.
- Every displayed subcontext must be speakable.

## Pull requests

Keep pull requests small and explain the user-facing behaviour, the evidence for the change, and how you tested it. New behaviour should include focused tests where practical.

Use the pull-request checklist. Never include personal vault content, locally
generated snapshots, credentials, signing identities, or machine-specific
Xcode state. By participating, you agree to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
