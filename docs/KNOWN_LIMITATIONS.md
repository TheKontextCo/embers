# Known limitations

Embers is an early macOS developer preview. These are current product
boundaries, not promises about future scope.

## Platform and installation

- Source builds and public artifacts require an Apple silicon Mac running
  macOS 26 or later and Swift 6.2 for development.
- Public artifacts are arm64-only. Intel Macs and older macOS releases are not
  supported.
- Updates are manual. Embers does not fetch an update feed or replace itself.
- A sandboxed release cannot silently import caches or preferences from an
  older unsandboxed build. Select the source folder again to create a fresh
  security-scoped bookmark and local snapshot.

## Sources and indexing

- The built-in local source targets Markdown folders and Obsidian-style vaults.
  Unsupported binary formats are not interpreted as note content.
- Folder access is limited to locations the user selects. Moving, renaming, or
  revoking access to a folder can require selecting it again.
- Indexes and provider snapshots are local caches derived from their sources;
  source files remain authoritative.

## Voice and models

- Voice control depends on macOS microphone and speech-recognition permission,
  the selected input device, and Apple's speech services. Typed and pointer
  interaction remain the fallback when recognition is unavailable.
- Apple's on-device Foundation Models integration is optional and abstains when
  the model or Apple Intelligence is unavailable. Core folder indexing and
  deterministic retrieval do not require it.

## Network and providers

- The local-folder path requires no account or network request.
- A provider such as Kontext uses the network only after the user explicitly
  connects it and remains subject to that provider's availability and
  authentication boundary.

Please submit compatibility results through the repository's compatibility
report form. Never attach personal vault content or unredacted logs.
