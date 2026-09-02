# Voice hit detection: the operating model

Voice routing is not search with a microphone. It is a precision instrument operating on a
speculative, continuously revised time series.

The recognizer guesses words. The compiler proposes vocabulary. Deterministic code decides what
those words are allowed to mean. The interface spends the result.

That separation is the system.

```text
source graph
  → grounded routing seeds
  → Apple model proposals
  → deterministic validation
  → immutable routing pack
  → every partial transcript
  → exact identity | shared concept | abstain
  → peek candidates
  → explicit local preference
```

## The laws

1. Identity is not similarity.
2. Association is not identity.
3. Ambiguity is information, not an error.
4. A model may propose; it may not route.
5. Precision comes from permission, not confidence.
6. Latency is a time-series problem, not a debounce problem.
7. Suppression belongs to an occurrence, not a recognizer session.
8. User behavior may rank valid choices; it may not manufacture validity.
9. The active pack is executable truth. Everything else is commentary.
10. Abstention is a successful result.

## What Apple actually gives us

`SFSpeechRecognizer` does not deliver a stable sentence one word at a time. It delivers a running
hypothesis. A sequence such as:

```text
hearing: Know
hearing … ledge
```

does not mean the router saw two fragments. Embers logs only the newly appended suffix when the
latest hypothesis extends the previous one. The router received `Know`, then `Knowledge`.

Apple may also revise rather than append:

```text
progressive Sumatran
progressive summarizing
progressive summarization
```

Each line is a new hypothesis, not an edit instruction. A match may appear, disappear, or become
unsafe as the hypothesis changes. Finality is useful, but waiting for it makes the interface feel
dead. A fixed debounce has the same defect: it prices every easy hit as if it were hard.

The hot path therefore evaluates every changed partial. Work may be duplicated. Latency is bought
with compute; precision is bought with deterministic gates.

`contextualStrings` only bias recognition. They do not create routing authority. A phrase can be in
Apple's vocabulary and still abstain. A phrase can be recognized perfectly and still be too broad.

## Three outcomes, not one winner

Every transcript resolves into one of three forms.

### Exact identity

A canonical name or existing alias is an address. It routes immediately. Longer, more specific
identity owns a contained shorter identity: `Building a Second Brain` outranks `Brain` over the same
span. Identity is not forced through semantic scoring.

### Shared concept

A broad phrase may be valid evidence for several nodes. `Knowledge management` can honestly point
at a project, a methodology, and a taxonomy tag. Destroying two answers to manufacture one answer
does not create precision; it hides uncertainty.

The compiler preserves that phrase as a shared concept with evidence-backed candidate edges. The
runtime returns at most three. The notch presents choices. It never auto-navigates a shared group,
even when already open.

### Abstention

Generic conversation, prompts asking how to trigger the system, unsupported vocabulary, unsafe
collisions, and insufficiently specific concepts produce nothing. There is no forced winner.

`Knowledge` alone is a subject class, not an address. `Knowledge system` can be an executable shared
concept. The extra word is not cosmetic; it narrows the permission boundary.

## Compile meaning; do not improvise it live

The model is useful where latency is irrelevant and inspection is possible. It is dangerous where
an answer must be immediate and silent failure is hard to see.

Embers compiles each voice-addressable graph node into a routing card in the background. A seed
contains identity and bounded direct evidence: canonical name, authored aliases, kind, direct
artifact titles, headings and tags, and short direct excerpts. Ancestry and children are contrast,
not positive evidence. Descendant content is never flattened into a parent.

The local Apple model proposes shortenings, conventional synonyms, phrase families, artifact
vocabulary, representative utterances, confusers, and hard negatives. Several independent proposal
passes improve recall. None of their output is executable merely because it was generated.

Deterministic validation rejects:

- generic standalone words
- metadata, paths, URLs, IDs, frontmatter, and boilerplate
- unsupported distinctive terms
- descendant or context-only contamination
- global alias collisions
- positives that do not route back to their source
- hard negatives that fail to abstain
- confusers that still route to their owner

Generated material has three inspectable destinations:

- `activeTriggers`: executable production vocabulary
- `descriptiveVocabulary`: grounded context that is useful to inspect but cannot trigger
- `rejectedTriggers`: proposed phrases with deterministic rejection reasons

The JSON is a proof artifact. Richness in a card is not the same as reachability in the hot path.
Only active triggers and validated shared concepts execute.

## Shared concepts are compiled ambiguity

Earlier designs treated a collision as evidence that both phrases should be deleted. That protected
precision but destroyed legitimate recall. The correction was to model the collision itself.

For each ambiguous phrase, the compiler independently restores each possible owner and runs it
through the production router. A node becomes a candidate edge only when it clears the actual score,
evidence, negative, and overlap rules. Two or more valid owners form a stable shared concept. One
valid owner becomes a unique trigger. Zero owners remain rejected.

The concept ID is derived from the normalized pattern, not from candidate ordering. Candidate
membership can improve without erasing local preference history.

Equivalent phrase and ordered-term patterns are deduplicated for the same occurrence. A contiguous
phrase wins over its looser ordered form. A genuinely separate gapped occurrence remains distinct.

This gives ambiguity a durable representation:

```text
concept pattern
  → candidate A + evidence hash + compiled strength
  → candidate B + evidence hash + compiled strength
  → candidate C + evidence hash + compiled strength
```

No candidate exists because it is merely nearby in embedding space. Every edge has provenance.

## Runtime is deterministic and model-free

The shipping hot path receives an immutable pack and a running transcript. It performs normalization,
whole-phrase or bounded ordered-term matching, identity precedence, hard-negative and confuser
blocking, score and margin gates, shared-concept grouping, preference ordering, suppression, and
retraction. It performs no model request.

The model can be unavailable forever and exact identity still works.

The compiler can take minutes because runtime takes microseconds. This is the useful bargain:
expensive thought once, cheap judgment repeatedly.

## Suppression is temporal state

Without suppression, every partial re-presents the same result:

```text
second
second brain
put this in my second brain
```

Suppressing everything for the recognition session fixes duplication by deleting future intent.
Apple may keep one recognition task alive across several spoken thoughts. Thirty seconds later, a
real repeated concept can share the same `utteranceID`.

The unit of suppression must therefore be the matched occurrence.

For each shared concept, Embers tracks how many distinct occurrences in the normalized running
transcript have already been consumed:

- transcript growth that retains one old occurrence does not replay it after the peek expires
- a second occurrence in the accumulated transcript re-arms the concept
- if Apple removes the phrase and later restores it, the falling then rising occurrence count
  re-arms it
- mentions arriving while the concept's peeks are still visible are consumed, preventing a delayed
  ghost hit after those peeks expire
- a new recognizer session resets temporal suppression, while still-visible peeks remain suppressed

This is event-time logic. A 30-second cooldown would be simpler and wrong. Time passing is not proof
of new intent. A new occurrence is.

Unique nodes follow the same principle at node granularity: suppress while their positive trigger
remains present or while the node is already visible; release when the trigger leaves the running
hypothesis.

## Partial positives require reversible presentation

Immediate partial matching creates a precision problem: a positive can arrive before its negative.

```text
journal
journal templates
```

If `journal templates` is a hard negative, waiting would avoid the first peek but ruin latency for
every clean `journal`. The better solution is speculative presentation with deterministic retraction.

Embers surfaces the early positive, evaluates every correction and suffix, and removes only the
specific node or shared concept invalidated by the later evidence. Other peeks survive. A shared
concept can also narrow from three candidates to two when a suffix blocks only one candidate.

Fast does not mean irreversible.

## The peek queue is part of routing correctness

The queue can hold three peeks. That limit does not stop scanning. A visible node suppresses only
itself. A visible shared group suppresses its own candidates while unrelated concepts remain eligible.

When the notch is closed, unique and shared peeks can coexist. When open, only shared candidates are
shown as a choice row; unique hits use their normal navigation behavior. Replacing a shared concept's
candidate order must not disturb unrelated peeks or their timers.

Presentation state is not decoration. The router needs it to decide whether a new hit is useful.

## Learning is a ranking overlay, not a new ontology

Compiled packs are shared truth about what may match. Personal behavior is local evidence about which
valid destination a user prefers.

An explicit open of a shared candidate adds a small, capped association for:

```text
source + concept + node
```

The weight decays with a 30-day half-life. It can reorder candidates before the three-item cap. It
cannot turn an invalid edge into a valid one, change unique identity routing, or bypass a negative.

Presentations, automatic opens, abstentions, retractions, and dismissals do not teach. Absence of a
click has too many meanings to be clean negative evidence.

The preference store is local, inspectable, source-scoped, resettable, and deleted with its folder.
Connected sources keep separate histories. Delayed writes carry source epochs so reset or folder
removal cannot be undone by an old asynchronous task.

The compiled pack answers: **what is allowed?**

The preference overlay answers: **among allowed choices, what has this user chosen before?**

Mixing those questions would make the system less explainable with every use.

## Cache and activation are correctness boundaries

Cards are cached per graph revision, evidence hash, compiler/schema version, and model/OS identity.
Builds are resumable. A complete pack is structurally validated and quality-gated before activation.
Corrupt JSON, duplicate cards, stale graph revisions, or incomplete builds never become runtime state.

The activation gate validates production triggers, canonical identities, negatives, confusers, shared
concepts, coverage, and the fixed regression corpus repeatedly. Tests that call a dormant semantic
matcher do not prove shipping behavior; evaluations must call the same stream router owned by the app.

One remaining operational debt is important: when a new compilation begins, the app currently falls
back to names-only routing instead of retaining the matching last-good pack until atomic replacement.
That creates a temporary recall blind spot. Compilation status is therefore part of diagnosis, not
just Settings decoration. The durable rule is stricter: rebuild beside the active pack, then swap.

## Observability must explain absence

`abstained or held` compresses several different states into one useless sentence:

- no executable pattern matched
- a negative blocked the match
- the score or margin failed
- a shared concept had no surviving candidate
- the occurrence was already consumed
- the candidate was already visible
- only names were active while compilation was running

Those states have different fixes. Privacy-safe logs should include the normalized trigger or stable
trigger ID, concept ID, occurrence count, candidate titles, compiled strengths, preference boosts,
blocker reason, suppression reason, and pack state. They should never include note excerpts.

Likewise, suffix logging should be described honestly: `hearing … ledge` is a display optimization,
not the text passed to routing.

The fastest debugging tool is often the active `voice-routing.json`. It answers four questions:

1. Was the phrase proposed?
2. Was it active, descriptive, rejected, or promoted to a shared concept?
3. Which nodes own it, and with what provenance?
4. Is this exact graph revision and compiler generation active in the running process?

## What failed, and what it taught us

`Come on man` routing to Projects taught us that a model-selected winner and self-reported confidence
are not precision. Confidence is not permission.

`I need to write in my diary` missing Journal taught us that representative examples stored in JSON
do nothing unless the shipping runtime executes them. Tests must cross the production seam.

`Second brain` working only as the full canonical name taught us that obvious canonical fragments
must be compiled deterministically; model recall is stochastic.

`Knowledge system` failing despite appearing in card data taught us to separate descriptive evidence
from active triggers, then to represent valid collisions instead of deleting them.

`Knowledge management` showing three candidates once, then never again, taught us that recognizer
sessions are not utterances and that suppression is an occurrence-counting problem.

`Journal` appearing before a later negative taught us that low latency requires retraction, not delay.

Copied template placeholders becoming speakable taught us that provenance is structural. Names are
not invalid because they look generic; evidence is invalid when its lineage is inherited scaffolding.

Compiler success during tests but failure in the app taught us that a parallel semantic matcher is
not a safety net if production never calls it. One runtime must define truth.

## The compact doctrine

Precompute broadly. Activate narrowly.

Match every partial. Present reversibly.

Let identity navigate. Let concepts offer choices. Let generic speech disappear.

Remember explicit choices, not inferred rejection.

Re-arm on new evidence, not elapsed time.

Keep the model off the hot path and inside a glass box.

The goal is not to make every phrase hit. The goal is that every hit deserves to exist.
