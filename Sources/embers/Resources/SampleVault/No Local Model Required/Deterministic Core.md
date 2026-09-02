# Deterministic Core

Embers builds a graph from folder structure and Markdown evidence. The graph
records which documents belong to each context and keeps references to the
original files. A result leads back to something you can open and read.

## Names before suggestions

Full titles, authored aliases, and contiguous title words provide the baseline
for voice matching. A fragment made only of filler words does not become a
trigger. An exact full title takes priority over another context's title fragment.

When a fragment belongs to several contexts, Embers presents small previews
called peeks, up to three at a time. It does not silently assign the phrase to
whichever context happened to be indexed first.

## Keep the evidence

The model can suggest vocabulary; code decides which rules become active and
which source material a match retrieves. Suggested names do not move documents
between folders or rewrite their contents.

Embers builds and validates replacement snapshots before publishing them. A
failed rebuild leaves the last good snapshot available. The source files remain
the basis for rebuilding the graph, whether or not a language model is available.
