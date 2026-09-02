## Summary

What problem does this solve, and what evidence shows it is the right boundary?

## User-visible behaviour

Describe what changes for a person using Embers. Write “None” for internal-only changes.

## Testing

- Focused red/green regression:
- `swift test`:
- `./scripts/verify-repository-readiness.sh`:
- `./scripts/test-release-scripts.sh`:
- `git diff --check`:
- Signed-app manual proof, when applicable:

## Privacy and architecture

- [ ] User content remains on-device unless an explicitly connected provider owns the request.
- [ ] Tests and fixtures contain only synthetic or bundled data.
- [ ] No credentials, snapshots, caches, absolute user paths, signing state, or Xcode user data are included.
- [ ] Deterministic code still owns identity, evidence, containment, ranking, validation, and retrieval.

## Review checklist

- [ ] The change is focused and linked to an issue or clearly stated problem.
- [ ] New behaviour or a bug fix has a focused test where practical.
- [ ] Documentation and known limitations are updated when their contract changes.
