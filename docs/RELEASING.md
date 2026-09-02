# Releasing Embers

Embers releases are operator-built artifacts. The shipped app has no automatic
update checker, feed fetch, analytics, or network request. A user decides when
to visit the release page, download an asset, and install an update.

## Prerequisites

- A clean commit tagged exactly `vVERSION` (for example `v0.1.0`) and a macOS
  build host.
- A **Developer ID Application** certificate installed in the active keychain.
- A `notarytool` keychain profile created from App Store Connect credentials.
  Keep those credentials out of this repository and CI logs.
- Xcode command-line tools, including `codesign`, `hdiutil`, `notarytool`,
  `stapler`, and `spctl`.

The bundle identity and minimum macOS version come from `Resources/Info.plist`.
Public disk images are Apple-silicon-only (`arm64`) and require macOS 26.0 or
later. `scripts/verify-distribution-binaries.sh` rejects a release if any
executable, framework, helper, or plug-in payload contains a non-arm64 slice or
declares a different deployment target.
The release script refuses a dirty worktree, an ad-hoc signature, a missing
secure timestamp, missing notarization credentials, or a release binary that
contains a personal home-directory build path. SwiftPM release intermediates
are built under a temporary neutral path for this reason.

The shipped app is App Sandbox constrained. It has access only to folders the
person explicitly selects (held through a security-scoped bookmark), microphone
input, and outbound connections used by an explicitly connected Kontext
account. The signed release check rejects broad
filesystem and temporary filesystem-exception entitlements.

The Hardened Runtime uses no exceptions. In particular, the signed release
must not allow JIT or unsigned executable memory, disable executable-page or
library validation, accept DYLD environment overrides, expose a debugger port,
or carry `get-task-allow`. Embers uses Apple system frameworks, including
FoundationModels, directly; model availability is checked at runtime and the
feature safely abstains on ineligible hardware or when Apple Intelligence is
unavailable.

An update from an older unsandboxed build does not automatically import its
Application Support caches or preferences: the sandbox is deliberately unable
to read that old location without a user grant. This preserves the meaning of
Forget Folder and avoids resurrecting cached private content. The original
folder remains untouched; select it again in the sandboxed app to create a new
scoped bookmark and rebuild a fresh local cache.

## Build a release

```bash
export EMBERS_SIGNING_IDENTITY='Developer ID Application: Your Team (TEAMID)'
export EMBERS_NOTARY_KEYCHAIN_PROFILE='embers-notary'
./scripts/release.sh 0.1.0 1
```

The script writes `build/release/`:

- `embers.app` — Developer ID signed, secure-timestamped, notarized, and stapled.
- `embers-VERSION-macos.dmg` — Developer ID signed, notarized, and stapled
  drag-to-Applications disk image.
- `embers-VERSION-macos.dmg.sha256` — SHA-256 verification file.
- `release.json` — machine-readable artifact metadata.

The DMG uses only Apple tooling and contains exactly `Embers.app` and a link to
`/Applications`. It intentionally has no scripted Finder layout, custom window,
or third-party packaging dependency. The app is notarized and stapled before it
is copied into the DMG; the completed DMG is then separately signed, notarized,
and stapled.

`update-manifest.json` is embedded in `embers.app/Contents/Resources` before
codesigning. It is the signed, versioned release manifest and declares the
manual update policy. The external `release.json` carries the DMG filename
and checksum produced after signing/stapling, so it is deliberately not treated
as an update authority.

Run this offline artifact check before uploading anything:

```bash
./scripts/verify-release.sh \
  build/release/embers.app \
  build/release/embers-0.1.0-macos.dmg \
  build/release/embers-0.1.0-macos.dmg.sha256 \
  build/release/release.json
```

The verifier runs without network requests. It checks the DMG checksum,
Developer ID signature, secure timestamp, stapled ticket, Gatekeeper assessment,
top-level layout, and the embedded app's identity, entitlements, provenance,
architectures, signature, and stapled ticket. A byte-identical DMG is not
promised across separately signed builds because Apple signing and notarization
attach time-varying data.

## Publish and update policy

Upload the DMG, its `.sha256`, and `release.json` together only after the
verification command passes. Publishing is intentionally a separate, explicit
operator action; the scripts and CI workflow do not create a GitHub Release.

Users update manually: download a newer release, verify the SHA-256 file and
Gatekeeper signature, open the DMG, quit Embers, then drag the app into
`/Applications` to replace the old copy.
Keep prior release assets available so a user can download an earlier verified
version and repeat the same replacement steps to roll back. Do not advise users
to delete `~/Library/Application Support` data as part of a rollback.

If an in-app updater is later proposed, it must have an explicit opt-in, a
signed update feed, a documented privacy boundary, and a separate security
review. It is not implied by these manifests.
