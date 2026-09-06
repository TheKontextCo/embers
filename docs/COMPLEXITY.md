# Complexity gate

Run `./scripts/verify-complexity.sh` with SwiftLint **0.65.1** on your PATH,
or set `EMBERS_SWIFTLINT` to that version's executable. The check is offline,
does not write a cache, and scans `Sources` and `Tests` without autocorrection.
Run `./scripts/test-complexity-gate.sh` to verify the real analyzer's 20/21 boundary.

The configuration enables only cyclomatic complexity: warnings above 10,
errors above 20, with switch cases counted. Warnings do not fail the gate.
CI installs the pinned official portable macOS release and verifies its SHA-256.
For local installation, download `portable_swiftlint.zip` from
https://github.com/realm/SwiftLint/releases/tag/0.65.1 and verify:

```text
c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
```

The historical `complexity-baseline.json` records the pre-refactor snapshot;
it does not suppress violations. The 20 ceiling prevents all four historical
hotspots from exceeding 20, and rejects every new function above 20.

Use this metric to locate functions that are difficult to reason about and test.
Extract named domain phases with explicit inputs, results, and mutation ownership.
Preserve ordering, error semantics, cache publication, and observable diagnostics.
Characterize those behaviors before extraction and remeasure the resulting helpers.
Flattening nesting can improve readability without changing this score. Avoid
arbitrary helper extraction, blanket suppressions, or replacing clear switches
solely to change a number. This gate establishes no performance or runtime proof.
