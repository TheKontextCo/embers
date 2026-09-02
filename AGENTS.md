# AGENTS.md

## Product

Embers is an open-source, local-first macOS context engine:

```text
local folder → deterministic graph → voice match → useful context
```

A first-time user should select an Obsidian vault or Markdown folder and get useful results without an account, network request, model, or manual setup.

## Invariants

- User content stays on-device. Network access is limited to providers the user explicitly connects.
- Deterministic code owns identity, evidence, containment, ranking, validation, and retrieval. LLM output is only a grounded proposal.
- Keep two connected graphs: source hierarchy and evidence-backed semantic relations.
- Never flatten descendants into direct parent results.
- Frontmatter, Notion IDs, export paths, URLs, and boilerplate are metadata—not semantic mentions.
- Main-list prominence and voice addressability are separate. Every displayed subcontext must be speakable.
- Models are optional. Model work must be local, cached, resumable, and evidence-gated.
- **Context Lens** is the product name for inspecting optional model work. It must expose bounded inputs, model proposals, and deterministic decisions separately.
- Opening Context Lens must never invoke a model, mutate a source, or transmit user content. Its current product surface is a source-scoped JSON export opened through the source overflow menu.

## Architecture

```text
embers (UI / speech / composition)
  → EmbersLocal (filesystem / parsing / persistence)
    → EmbersCore (domain / graph / retrieval / protocols)
```

- `EmbersCore` uses Foundation only.
- Inject dependencies; do not add new reaches into `AppState.shared`.
- Build immutable snapshots off-main, validate, then atomically replace.
- Preserve the last good snapshot on rebuild or enrichment failure.

## Verify

```bash
swift test
git diff --check
./scripts/bundle.sh debug
open build/embers.app
```

Use the signed bundle for UI and speech testing, not the raw SwiftPM executable.

## Safety

- Preserve unrelated work in a dirty worktree.
- Never commit personal data, snapshots, caches, model output, credentials, absolute user paths, or `.swiftpm/xcode/xcuserdata`.
- Use synthetic or bundled fixture data in tests.
- Current code and tests are authoritative.
