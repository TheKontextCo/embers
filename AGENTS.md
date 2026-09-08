# AGENTS.md

## Product

Embers is an open-source, local-first macOS context engine:

```text
local folder → deterministic graph → voice match → useful context
```

A first-time user should select an Obsidian vault or Markdown folder and get useful results without an account, network request, model, or manual setup.

## Kontext project updates

- Save relevant Kontext project discussions, progress, findings, decisions, tasks, and documents automatically; no separate confirmation is required.
- Update existing records where appropriate and keep task status current.

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

## Behaviour-change gate

This gate applies to agents implementing changes in this repository. Before implementing any change that affects user-visible behaviour, persistent state, routing, permissions, or recovery, define the complete behavioural contract.

- Classify every relevant input by semantic event. At minimum, distinguish explicit choice or mutation, passive presentation, automatic open, abstention, retraction, dismiss, inspect, undo, and durable reset. Declare which events may write or teach. Presentation, automatic open, abstention, retraction, dismiss, and inspect are neutral and must never create durable learning or other side effects. Feature-specific operating models such as `docs/VOICE_HIT_DETECTION.md` are authoritative where they define a more precise contract.
- Identify the authoritative state, persisted state, derived snapshots, and all asynchronous work that can publish into them.
- Define the canonical identity of the behaviour and any equivalent representations that must share the same result.
- Define when the operation has genuinely succeeded, how failure is shown, and how retry, cancellation, interruption, undo, and reset behave.
- Define the scope of durable changes. Learning, reset, and recovery must be scoped to the correct source, context, or provider.
- Keep Context Lens scoped to optional model work: bounded inputs, model proposals, and deterministic accept-or-reject decisions. Expose other deterministic runtime decisions through their domain-specific inspectable state, artifacts, or privacy-safe logs.

### State and concurrency

- A mutation must invalidate, cancel, or supersede older asynchronous work before that work can publish stale state.
- Every asynchronous snapshot publisher must prove that its result is still current before replacing accepted state.
- Preserve the last good immutable snapshot until a complete replacement has validated.
- Never allow completion order, callback timing, filesystem order, or task scheduling to become hidden behavioural authority.

### Persistence and recovery

- Do not present success until the durable write has succeeded and the accepted runtime state reflects it.
- Persistence, undo, reset, and reload failures must be visible and recoverable; logging alone is insufficient when the UI claims success.
- Durable behaviour requires a durable, appropriately scoped reset or recovery path.
- Retries and interrupted operations must be idempotent where repetition is possible.

### Required proof

Happy-path tests are not sufficient for behaviour-changing code. Add focused deterministic coverage for every applicable case:

- stale work completing after a newer mutation;
- cancellation and interruption;
- persistence failure followed by retry;
- equivalent identity or sibling representations;
- explicit choices that are intended to teach or mutate doing so, while presentation, automatic open, abstention, retraction, dismiss, and inspect remain side-effect free;
- undo and reset durability;
- preservation of unrelated routes, sources, and accepted state.

For UI, speech, permissions, or lifecycle behaviour, verify the signed application bundle. A change is not complete until the pull request identifies the evidence for each changed behaviour and clearly states any remaining unverified boundary.

## Verify

```bash
swift test
./scripts/verify-complexity.sh
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
- `TheKontextCo/embers` is the canonical repository and must remain `origin`.
- `TheKontextCo/embers-private-backup` is archival backup only. Never fetch from it, branch from it, push to it, open or update pull requests there, or use it as implementation evidence unless the user explicitly requests backup recovery.
