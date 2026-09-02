# Roadmap

Planned improvements, not promises about the current release. Items remain open
until implementation, regression tests, and manual verification are complete.

## Progressive voice vocabulary

- [ ] Make validated vocabulary available before enrichment finishes.

**Status:** Planned. No implementation yet. Not a source-release blocker.

### Why

The first vocabulary build can take minutes even for the three-context sample
vault, based on a user report on an M1 Max; we have not measured the individual
stages yet. The compiler currently makes up to eight model requests per uncached
context, processes contexts sequentially, and activates the expanded vocabulary
only after validating the combined pack.

Title matching and authored aliases already work after indexing, without
waiting for the model. This improvement targets the wait for additional phrases,
not those existing matches or necessarily the total build time.

### Proposed approach

1. **Basic vocabulary:** run the spoken-name proposal across all contexts.
   Validate only candidates with sufficient evidence and activate the combined
   result. Do not treat pending verification as successful verification.
2. **Enrichment:** run the remaining model passes, validate the combined result,
   and replace the basic vocabulary. Keep the last valid stage if enrichment
   fails.

Validate each stage across all contexts before activation so processing order
does not give a shared phrase to an arbitrary project. Start with two stages,
not a separate activation after every model request.

### Work and acceptance criteria

- [ ] Measure cold-build time to basic vocabulary and full enrichment on the
  sample vault; record hardware and cache state.
- [ ] Split compilation and publication into basic and enriched stages without
  weakening evidence, collision, or regression checks.
- [ ] Distinguish partial and complete cache/status state. Restarting must not
  mistake a basic pack for completed enrichment.
- [ ] Preserve the last valid stage on failure and reject late results after
  source changes or cancellation.
- [ ] Keep Context Lens clear about available proposals and deterministic
  decisions at each stage.
- [ ] Write tests first for early availability, collisions, failure, restart,
  and cancellation. Vocabulary updates during an utterance must not retrigger
  or retract existing peeks, or replace them with only the newest match.
- [ ] Preserve the one-, two-, and three-project multi-peek regressions and
  verify the progressive build manually before merging.

The current router resets utterance tracking when replacing a vocabulary pack;
progressive publication must address that explicitly. Reducing the total model
call count is a separate proposal, not part of this roadmap item's scope.
