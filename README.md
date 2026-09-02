# Embers

**Say a project name. Bring its context to your notch.**

Embers is an open-source Mac app that brings up the notes, links, and tasks
related to what you're talking about. Point it at an Obsidian vault or Markdown
folder, start listening, and say a project name. A small preview—a peek—appears
at the notch. Open it to explore the context and jump to the original files.

Keep up to three projects in view as the conversation moves between them.
Your local notes and voice stay on your Mac.

https://github.com/user-attachments/assets/1df8d0ef-44b8-47e0-a402-41040c9c1320

[Download for Mac](https://github.com/TheKontextCo/embers/releases/latest) · [Build from source](#build-from-source) · [Try the sample vault](#try-the-sample-vault) · [How it works](#how-it-works)

## Download for Mac

Download the signed and notarized disk image from the
[latest GitHub Release](https://github.com/TheKontextCo/embers/releases/latest),
open it, and drag Embers into Applications. It requires an Apple-silicon Mac
running macOS 26 or later. Each release includes an adjacent SHA-256 file for
verifying the download.

## Build from source

You can also build the developer preview on your own Mac:

- Apple silicon and macOS 26 or later.
- [Xcode](https://developer.apple.com/xcode/) with Swift 6.2 or later and the
  macOS 26 SDK. Open Xcode once to finish setup, then select it under
  **Xcode → Settings → Locations → Command Line Tools**.

```bash
git clone https://github.com/TheKontextCo/embers.git
cd embers
./scripts/bundle.sh debug
open build/embers.app
```

The script builds and signs a local app bundle. No developer certificate is
required: it uses an Apple Development identity if available, otherwise an
ad-hoc signature. macOS may ask for permissions again after an ad-hoc rebuild.
Use this bundle for voice control, not the raw `swift run` executable.

Embers lives in the menu bar, with no Dock icon. Click the flame and choose
**Open Embers**. The same menu has **Start listening**, **Stop listening**, and
**Quit Embers**.

## Try the sample vault

You don't need your own notes or an Embers account to try it.

1. Choose **Try the sample vault** in Embers and wait for its three contexts
   to appear. Embers creates a local copy of the bundled Markdown files.
2. From the flame menu, choose **Start listening** and allow microphone and
   speech recognition when macOS asks.
3. Click inside Embers and press **Esc** to collapse the panel. Move the pointer
   away from the notch so it stays closed while you speak.
4. Say **“San Francisco.”** The **San Francisco Trip** peek should appear.
5. Say **“second brain.”** Its peek should appear alongside the trip.
6. Hover over the trip peek to open it, then open **Itinerary** to read the original Markdown
   file in your default app. Mark the sample's try-it tasks done as you go.

You can also select a context in Embers without using voice. When you're ready
for your own notes, choose **Use my folder…** in the sample banner. Select an
Obsidian vault or a folder containing Markdown files—not just any folder.

## What you can do

- Bring related notes, links, and tasks together without reorganising your vault.
- Keep several project peeks visible while you switch topics.
- Open the original files in the apps you already use.
- Complete Markdown tasks from Embers; the checkbox updates in the source file.
- Inspect why a phrase matches through **Context Lens**.

## How it works

Embers reads your folder structure, titles, links, and tasks to build a local
context graph. Matching rules connect spoken names to those contexts—for
example, “San Francisco” matches **San Francisco Trip** directly from its title.

When Apple Intelligence is enabled and its model is ready, Embers uses Apple's
on-device Foundation Models to propose additional ways you might refer to a
context. Code checks those suggestions against source evidence and competing
contexts before accepting them. Accepted rules are cached: speaking a phrase
doesn't trigger another model call.

If the model is unavailable, folder indexing, title matching, and authored
aliases still work.

### Context Lens

Context Lens lets you inspect that process: the evidence supplied to the model,
its proposals, and the matching rules code accepted or rejected. Title-based
rules are shown separately from model proposals.

In **Settings**, open a source's overflow menu and choose **Open Context Lens**.
Embers exports a source-scoped JSON file and opens it in your default app.
Opening it never reruns the model, changes your notes, or sends their content
anywhere.

### Architecture

```text
Embers (UI / speech / composition)
  → EmbersLocal (filesystem / parsing / persistence)
    → EmbersCore (domain / graph / retrieval / protocols)
```

`EmbersCore` uses Foundation only. Code owns matching and retrieval; model
output is a proposal, not an instruction. After the initial index, folder
refreshes run in the background and preserve the last good snapshot on failure.

## Privacy and limitations

Local-folder indexing and voice matching run on your Mac. Speech recognition
is on-device only; Apple may need to download speech or Apple Intelligence
assets before those features are available. Embers doesn't upload your notes
or audio. Providers such as Kontext contact their service only after you
explicitly connect them.

Intel Macs and macOS versions before 26 aren't supported. Updates are manual.
See [known limitations](docs/KNOWN_LIMITATIONS.md) for supported formats,
permissions, and model availability.

If voice isn't working, check microphone and speech-recognition access for
Embers in **System Settings → Privacy & Security**, and check the flame menu
for a Dictation prompt. You can keep browsing contexts with the pointer.

## Contributing and feedback

See the [roadmap](docs/ROADMAP.md) for planned improvements, including making
voice vocabulary available progressively while enrichment continues.

Try the sample vault and tell us the first thing that breaks. Mac model, macOS
version, the phrase you said, and what appeared make a useful report. See
[SUPPORT.md](SUPPORT.md); don't attach personal notes or unredacted Context Lens
exports. Report security issues privately through [SECURITY.md](SECURITY.md).

To work on the code, start with [CONTRIBUTING.md](CONTRIBUTING.md). Run the tests
from the repository root:

```bash
swift test
```

## License

Embers' project-owned material is offered under the [MIT License](LICENSE).
See [third-party notices](THIRD_PARTY_NOTICES.md) for included third-party material.
