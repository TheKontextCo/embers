# Local Intelligence

The words that describe a subject are not always the words you say aloud. A
language model can suggest alternative names and phrases from the meaning of
your notes. Embers uses Apple's Foundation Models for this work, on your Mac,
automatically when they are available.

## A bounded job

For each context, Embers supplies its title, existing aliases, and a limited
selection of document titles, headings, tags, and excerpts. The model receives
this selected evidence rather than unrestricted access to your folder.

Its response is a proposal. Code checks the proposed phrases for grounding and
collisions with other contexts. Some are accepted, some are rejected, and some
identify several contexts rather than one.

## Reuse the work

Embers caches proposals locally and validates them before activating matching
rules. When you speak, the router checks the recognized words against those
rules. It does not ask the language model to choose a context on each utterance.

If the language model is unavailable, title matching still works. Speech
recognition is separate from this vocabulary-building step.

## Context Lens

Choose “Open Context Lens” from a source's overflow menu to open a JSON file in
your default app. It separates the selected inputs, model proposals, and
deterministic decisions, including accepted and rejected triggers.

The export is assembled by code from existing data. Opening it neither calls a
model nor sends your notes anywhere. You can inspect a suggestion without asking
the model to explain itself again.

- [ ] Open Context Lens and find a title-based matching rule
