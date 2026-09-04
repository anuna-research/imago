---
id: SPEC-014
title: Harness Evolution Control Plane
status: implemented
version: 0.3.0
date: 2026-09-04
audience:
  - agent-authors
  - agent-operators
  - harness-evaluators
  - harness-developers
related:
  - SPEC-011 (Image-Based Agent Harness)
  - SPEC-012 (Agent Self-Modification Port)
  - SPEC-013 (Skill Definition Port)
research:
  - HarnessDev (arXiv:2609.01437)
---

# SPEC-014: Harness Evolution Control Plane

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT,
RECOMMENDED, NOT RECOMMENDED, MAY, and OPTIONAL are requirement terms.
Their meanings follow BCP 14 when they appear in all capitals.

## Orientation

**Intent:** Turn Imago self-modification into measured harness evolution.
Each candidate becomes a frozen image with evidence before promotion.

**Metaphor:** The live image is a breeding ground, not the production animal.
Candidates leave the ground, enter quarantine, and earn release independently.

**Structure:**

```text
 [active image] -> [disposable creator] -> [frozen candidate]
                                              |
                   [sealed tasks] -> [external evaluator]
                                              |
                           [decision record] -> [canary pointer]
```

Arrows carry immutable identifiers or append-only evidence.

**Decisions:**

- Candidate images are immutable after freeze.
- Creation, execution, evaluation, and promotion are separate roles.
- Promotion is an external control-plane action.
- Correctness, capability, activation, and cost are separate measurements.
- Matched protocol replicates determine capability and efficiency deltas.
- Evolution remains an optional ASDF subsystem.
- Runtime safety defects block trustworthy evolution measurements.
- Persisted inputs and OpenRouter responses are fully recognized before action.

**Load-bearing requirements:**

- [[SPEC-014-harness-evolution-control-plane#REQ-003]] enforces agent tool authority.
- [[SPEC-014-harness-evolution-control-plane#REQ-004]] makes invariant failures deny actions.
- [[SPEC-014-harness-evolution-control-plane#REQ-007]] freezes content-addressed candidates.
- [[SPEC-014-harness-evolution-control-plane#REQ-011]] separates evaluation roles.
- [[SPEC-014-harness-evolution-control-plane#REQ-020]] requires matched comparison cells.
- [[SPEC-014-harness-evolution-control-plane#REQ-024]] applies a conservative replicate gate.
- [[SPEC-014-harness-evolution-control-plane#REQ-032]] separates decision authority.

**Controls:**

- [[SPEC-014-harness-evolution-control-plane#CON-001]],
  [[SPEC-014-harness-evolution-control-plane#CON-002]], and
  [[SPEC-014-harness-evolution-control-plane#CON-006]] define bounded signed forms.
- [[SPEC-014-harness-evolution-control-plane#CON-003]] denies dispatch without
  agent authority or an explicit operator scope.
- [[SPEC-014-harness-evolution-control-plane#CON-004]] defines every promotion gate.
- [[SPEC-014-harness-evolution-control-plane#CON-005]] confines every managed path.
- [[SPEC-014-harness-evolution-control-plane#CON-007]] bounds matched held-out evidence.
- [[SPEC-014-harness-evolution-control-plane#CON-008]] bounds and closes OpenRouter responses.
- Persisted forms are at most 1 MiB, and the complete ledger is at most 64 MiB.
- OpenRouter responses are at most 1 MiB, with at most 16 tool calls.

**Open items:** None for version 0.3.

Reviewer `final-adversarial-review` approved implementation commit `e48ffe9`.

**Detail:** Requirements start at
[[SPEC-014-harness-evolution-control-plane#Functional requirements]].
Verification starts at [[SPEC-014-harness-evolution-control-plane#Tests]].

## Context

[[SPEC-012-self-modification-port]] permits controlled changes inside a live
SBCL image. A saved image can preserve those changes across boots.

HarnessDev shows that mutation alone does not establish improvement.
Useful evolution needs frozen candidates, role separation, matched evaluation,
held-out tasks, activation evidence, transfer checks, and explicit cost accounting.

Imago currently lacks that control plane. Several baseline seams also weaken
the validity of any experiment:

- Scaffolded binaries start a default echo agent after spawning the custom agent.
- OpenRouter does not complete multi-turn tool-result conversations.
- Tool advertisement does not constrain process-global dispatch.
- Reasoner transport failures can permit guarded actions.

This specification repairs those seams and adds an optional evolution package.
It does not place an optimiser inside the production agent.

## User profiles

### Harness creator

The creator runs an active image in a disposable process. The creator changes
code, prompts, schemas, or skills and emits activation evidence.

### Harness executor

The executor runs a frozen candidate against assigned tasks. The executor
cannot alter the candidate or decide its promotion.

### Harness evaluator

The evaluator owns task answers and scoring. The evaluator records correctness,
capability, activation, latency, tokens, and cost.

### Agent operator

The operator reviews an eligibility decision. The operator authorizes canary
or active promotion and can restore a prior pointer.

### Harness developer

The developer maintains providers, dispatch, safety gates, and the evolution
subsystem. The developer preserves the small default system.

## Happy paths

### HP-001 — Freeze a candidate

1. The creator starts from a recorded parent image.
2. The creator modifies a disposable working image.
3. The creator supplies changed components and activation evidence.
4. `freeze-candidate!` copies the image into a candidate directory.
5. The control plane hashes the copied bytes.
6. The control plane writes one validated manifest.
7. A second freeze using that identifier fails.

### HP-002 — Evaluate without leaking held-out tasks

1. The evaluator selects a sealed held-out task.
2. The executor launches the frozen image by immutable path.
3. The evaluator scores task correctness separately from diagnostics.
4. Both actors sign the campaign, protocol, completion, and resource evidence.
5. The evidence ledger appends the completed run.
6. The creator receives aggregate results only.

### HP-003 — Compare across executors

1. The evaluator defines one held-out comparison-cell template.
2. Baseline and candidate execute identical complete protocol replicates.
3. At least two executor identities appear across the matched replicates.
4. The report computes replicate, executor, token, and cost deltas separately.
5. Any executor regression or noisy replicate keeps the candidate ineligible.

### HP-004 — Promote through an external checkpoint

1. The operator requests an eligibility decision.
2. The decision lists every satisfied and missing gate.
3. An explicit authorizer accepts the candidate.
4. The control plane writes a canary pointer atomically.
5. The candidate directory remains unchanged.
6. The operator can restore the prior pointer.

## Functional requirements

### REQ-001 — Custom-agent entrypoint

`agent-main` SHALL accept an agent factory. Echo and serve modes SHALL use the
factory result. A scaffolded toplevel SHALL pass its `build-agent` function.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-001]],
[[SPEC-014-harness-evolution-control-plane#TEST-022]].

### REQ-002 — Canonical OpenRouter tool loop

The OpenRouter provider SHALL preserve canonical message lists. It SHALL emit
assistant content and canonical stop reasons. It SHALL encode tool results for
the next OpenAI-compatible request.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-002]],
[[SPEC-014-harness-evolution-control-plane#TEST-023]].

### REQ-003 — Per-agent tool authorization

Provider advertisement and runtime dispatch SHALL use the same agent tool
allowlist. Runtime dispatch SHALL reject tools absent from that allowlist.
An unbound `*current-agent*` value SHALL NOT grant operator authority alone.
`with-operator-tool-dispatch` SHALL establish the explicit operator scope.
`drive-stream` SHALL bind its supplied agent during every tool dispatch.
Threads that lose both scopes SHALL deny dispatch.
The `harness-eval` worker SHALL retain its calling agent authority.
During that worker's synchronous dynamic extent, dispatch SHALL use an
immutable snapshot of the calling tool allowlist. Rebinding agent state,
operator state, or Lisp's current-thread variable SHALL NOT widen it.

Recognized forms that mention thread creation or interruption primitives SHALL
be vetoed. This policy is not an OS isolation claim for deliberately concealed
thread primitives or detached descendants of evaluated code.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-003]],
[[SPEC-014-harness-evolution-control-plane#TEST-024]],
[[SPEC-014-harness-evolution-control-plane#TEST-051]],
[[SPEC-014-harness-evolution-control-plane#TEST-052]],
[[SPEC-014-harness-evolution-control-plane#TEST-065]].

### REQ-004 — Fail-closed invariant checks

An installed invariant filter SHALL veto when its reasoner query fails or
returns malformed evidence. The self-modification port SHALL follow the same
rule.

Fact assertion or retraction failures SHALL veto self-modification before
evaluation. Safety-fact installation failures SHALL leave every guarded tool
unregistered and every evaluation permission disabled.

A valid proof result is a finite proper property list containing exactly one
each of `:tag`, `:derivation`, and `:time-ms`. The tag SHALL be one of the four
documented positive or negative proof tags. Derivation SHALL be a proper list
or `nil`, and time SHALL be a nonnegative integer. Every other shape is
malformed and SHALL deny the guarded action.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-004]],
[[SPEC-014-harness-evolution-control-plane#TEST-025]],
[[SPEC-014-harness-evolution-control-plane#TEST-054]],
[[SPEC-014-harness-evolution-control-plane#TEST-055]],
[[SPEC-014-harness-evolution-control-plane#TEST-065]].

### REQ-005 — Optional subsystem

Evolution APIs SHALL load only through `imago/evolution`. Loading `imago` SHALL
NOT create an evolution store or register evolution tools. Candidate processes
SHALL NOT receive the control-plane system, store authority, or store path.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-005]].

### REQ-006 — Explicit responsibility records

Every actor SHALL use a `did:key` identity. Candidate, evaluation, and
promotion records SHALL carry signatures from their responsible actors.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-006]],
[[SPEC-014-harness-evolution-control-plane#TEST-036]],
[[SPEC-014-harness-evolution-control-plane#TEST-060]],
[[SPEC-014-harness-evolution-control-plane#TEST-061]].

### REQ-007 — Immutable candidate freeze

`freeze-candidate!` SHALL copy an image into a new candidate directory. It
SHALL bind the candidate identifier to a SHA-256 image digest. It SHALL NOT
overwrite an existing candidate.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-007]],
[[SPEC-014-harness-evolution-control-plane#TEST-026]].

### REQ-008 — Candidate lineage

Every non-root candidate SHALL name its parent candidate and parent image
digest. Verification SHALL reject a missing parent or digest mismatch.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-008]],
[[SPEC-014-harness-evolution-control-plane#TEST-032]].

### REQ-009 — Harness surface manifest

Every candidate SHALL record prompt-schema, tool-schema, and theory digests.
It SHALL record changed components, budgets, and activation evidence.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-009]].

### REQ-010 — Append-only evidence ledger

Freeze, evaluation, decision, promotion, and rollback events SHALL append to a
single hash-chained store ledger. Readers SHALL reject malformed complete
entries and broken chains.

Every reader SHALL compare the complete chain with its signed terminal head.
Every append SHALL reject a projected size above the reader ceiling before any
ledger or head mutation. Persisted decision readers SHALL re-derive decision
context fields from the exact signed evidence prefix.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-010]],
[[SPEC-014-harness-evolution-control-plane#TEST-027]],
[[SPEC-014-harness-evolution-control-plane#TEST-053]],
[[SPEC-014-harness-evolution-control-plane#TEST-056]],
[[SPEC-014-harness-evolution-control-plane#TEST-060]].

### REQ-011 — Evaluation role separation

A held-out evaluation SHALL use distinct creator, executor, and evaluator
identities. Executors and evaluators SHALL belong to configured disjoint trust
rosters. A promotion decision SHALL require their valid signatures.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-011]].

### REQ-012 — Correctness before capability

Eligibility SHALL retain correctness for every baseline-correct held-out
comparison cell. It SHALL NOT replace correctness with diagnostic quality.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-012]].

### REQ-013 — Repetition and cross-executor evidence

Eligibility SHALL require configured minima of at least two complete held-out
replicates and at least two distinct executor DIDs.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-013]].

### REQ-014 — Capability, activation, and cost metrics

Each evaluation SHALL record capability score, activation evidence, duration,
input tokens, output tokens, and estimated cost. Reports SHALL keep each metric
separate.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-014]].

### REQ-015 — External promotion

Candidate code SHALL NOT promote itself. `promote-candidate!` SHALL require an
eligible decision and a signature from a configured trusted authorizer.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-015]],
[[SPEC-014-harness-evolution-control-plane#TEST-028]].

### REQ-016 — Canary and rollback pointers

Promotion SHALL support `:canary` and `:active` pointers. Pointer updates SHALL
be atomic. Rollback SHALL restore the recorded prior candidate.

A missing pointer file SHALL fail when signed pointer evidence exists.
Rollback SHALL verify the prior candidate and SHALL tolerate corrupt current
image bytes. Deleted or corrupt manifests remain fatal during historical replay.
Each pointer authorization SHALL bind the exact immediately preceding evidence
head.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-016]],
[[SPEC-014-harness-evolution-control-plane#TEST-029]],
[[SPEC-014-harness-evolution-control-plane#TEST-058]],
[[SPEC-014-harness-evolution-control-plane#TEST-059]],
[[SPEC-014-harness-evolution-control-plane#TEST-061]].

### REQ-017 — No in-place candidate mutation

Verification SHALL recompute the candidate image digest. A changed image SHALL
invalidate evaluation and promotion operations.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-017]].

### REQ-018 — Baseline-relative decision report

A decision SHALL compare candidate and baseline held-out capability means. It
SHALL report capability delta and candidate development cost separately.
The signed manifest's development cost SHALL be retained when current image
digest verification fails; digest validity remains an independent gate.
It SHALL bind to the current ledger head and every unique held-out run.
Ledger replay SHALL re-derive the context-dependent decision fields from its
signed prefix. It SHALL retain candidate and baseline digest-valid gates as
signed point-in-time attestations. Promotion SHALL recheck both images against
their current bytes.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-018]],
[[SPEC-014-harness-evolution-control-plane#TEST-053]].

### REQ-019 — Signed evaluation protocol envelope

Every evaluation event SHALL contain the complete signed protocol envelope
defined by [[SPEC-014-harness-evolution-control-plane#CON-002]].

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-036]].

### REQ-020 — Matched comparison cells

Eligibility SHALL compare exactly equal baseline and candidate held-out
comparison-cell multisets within one campaign.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-037]].

### REQ-021 — Unique candidate cells

The evidence ledger SHALL reject duplicate comparison-cell rows for one
candidate and campaign.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-038]].

### REQ-022 — Campaign split isolation

Each `(campaign-id, benchmark-id, task-id)` tuple SHALL occur only in exposed
splits or only in the held-out split.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-039]].

### REQ-023 — Complete protocol replicates

A held-out repetition SHALL count one distinct complete protocol replicate
whose cell template equals every other counted replicate.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-040]].

### REQ-024 — Conservative replicate delta

Eligibility SHALL require the minimum reported per-replicate capability delta
to meet a configured positive threshold.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-041]].

### REQ-025 — Separated efficiency report

The decision report SHALL state baseline and candidate execution-token totals,
token means, runtime-cost totals, cost means, and signed deltas separately.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-042]].

### REQ-026 — Execution-token regression gate

Eligibility SHALL reject an execution-token delta above the configured
nonnegative maximum execution-token increase.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-043]].

### REQ-027 — Runtime-cost regression gate

Eligibility SHALL reject a runtime-cost delta above the configured nonnegative
maximum runtime-cost increase.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-044]].

### REQ-028 — Per-executor-config transfer gate

Eligibility SHALL require every matched trusted executor-config cohort delta
to meet the configured capability threshold.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-045]].

### REQ-029 — Changed-component activation coverage

Every changed candidate component SHALL have a held-out `:runtime-hit` record
covered by both actor signatures and bound to the frozen image digest.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-046]].

### REQ-030 — Complete-run attestation

Eligibility SHALL require `:run-complete-p t` for every matched baseline and
candidate held-out event.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-047]].

### REQ-031 — Disjoint authorizer roster

The configured authorizer roster SHALL be disjoint from the executor and
evaluator rosters.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-048]].

### REQ-032 — Creator-authorizer separation

A decision authorizer SHALL differ from both compared candidate creators.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-049]].

### REQ-033 — Single evaluation-plan context

A decision SHALL consume exactly one distinct evaluation-plan digest across
its selected baseline and candidate held-out events.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-050]].

### REQ-034 — Bounded provider response recognition

The OpenRouter provider SHALL recognize the complete bounded response grammar
before emitting any actionable tool frame. A malformed response SHALL terminate
without tool dispatch.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-023]],
[[SPEC-014-harness-evolution-control-plane#TEST-064]].

## Non-functional requirements

### NFR-001 — Determinism

Identical candidate bytes and manifest inputs SHALL produce the same candidate
identifier. Decision calculations SHALL be independent of ledger order.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-019]],
[[SPEC-014-harness-evolution-control-plane#TEST-031]],
[[SPEC-014-harness-evolution-control-plane#TEST-045]].

### NFR-002 — Bounded core impact

The default `imago` system SHALL gain no evolution runtime dependency. Core
changes SHALL remain limited to repaired execution seams and exported contracts.
The CI-counted core SHALL remain below 3,700 physical lines. This reviewed
ceiling includes the closed receipt recognizer required for safe inspection of
persisted audit evidence. The optional evolution subsystem contributes no core
runtime dependency. Capability/security and compactness are recorded as
separate gates, following HarnessDev's separation of capability and efficiency.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-005]] and the CI LOC
budget job.

### NFR-003 — Actionable decisions

An ineligible decision SHALL list every missing or failed gate. It SHALL not
return only a Boolean value.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-020]].

### NFR-004 — Safe recognition

Manifest, ledger, and pointer readers SHALL disable reader evaluation. They
SHALL validate a complete form before causing effects. Bounds apply before
allocation or persistent mutation. Canonical readers and the OpenRouter
recognizer SHALL avoid interning input-controlled symbols.

Receipt inspection SHALL accept only the two emitted record schemas through a
finite token vocabulary. It SHALL reject reader dispatch, quoting, escaped
symbols, unknown tokens, excessive source/depth/node/string/file resources, and
invalid Unicode before invoking the Lisp reader. Malformed history SHALL fail
closed during inspection and sequence recovery. Receipt writers SHALL preflight
the same grammar before consuming a sequence number. Escaped string characters
SHALL consume the same pre-read decoded-character budget as ordinary characters.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-021]],
[[SPEC-014-harness-evolution-control-plane#TEST-030]],
[[SPEC-014-harness-evolution-control-plane#TEST-056]],
[[SPEC-014-harness-evolution-control-plane#TEST-057]],
[[SPEC-014-harness-evolution-control-plane#TEST-062]],
[[SPEC-014-harness-evolution-control-plane#TEST-063]],
[[SPEC-014-harness-evolution-control-plane#TEST-064]],
[[SPEC-014-harness-evolution-control-plane#TEST-065]].

## Contracts

### CON-001 — Candidate manifest grammar

The manifest is exactly one Common Lisp property list followed by EOF.
Reader evaluation is disabled. Keys outside this closed set are invalid:

```text
manifest = (
  :version integer
  :candidate-id string
  :parent-id (string | nil)
  :parent-image-sha256 (sha256 | nil)
  :image-file relative-path
  :image-sha256 sha256
  :creator-did did-key
  :creator-signature ed25519-hex
  :created-at utc-string
  :theory-fingerprint sha256
  :prompt-schema-sha256 sha256
  :tool-schema-sha256 sha256
  :changed-components sorted-unique-string-list
  :budgets budgets
  :activation-evidence sorted-unique-string-list)
budgets = (
  :development-cost-microusd bounded-source-integer
  :wall-time-ms bounded-source-integer
  :input-tokens bounded-source-integer
  :output-tokens bounded-source-integer)
bounded-source-integer = integer in [0, 10^20 - 1]
sha256 = 64 lowercase hexadecimal characters
ed25519-hex = 128 lowercase hexadecimal characters
```

The reader SHALL recognize the whole grammar before returning data.
The creator signature covers every manifest field except itself.

### CON-002 — Evidence event grammar

Each ledger line is exactly one property list. Evaluation events use this
exact closed field order:

```text
evaluation = (
  :event :evaluation
  :timestamp utc-string
  :candidate-id string
  :run-id string
  :campaign-id string
  :benchmark-id string
  :split split
  :task-id string
  :replicate-index positive-integer
  :evaluation-plan-sha256 sha256
  :executor-config-sha256 sha256
  :scorer-config-sha256 sha256
  :executor-did did-key
  :evaluator-did did-key
  :run-complete-p boolean
  :task-correct-p boolean
  :capability-score-micros bounded-source-integer
  :activation-evidence activation-evidence
  :duration-ms bounded-source-integer
  :input-tokens bounded-source-integer
  :output-tokens bounded-source-integer
  :estimated-cost-microusd bounded-source-integer
  :executor-signature ed25519-hex
  :evaluator-signature ed25519-hex
  :seq positive-integer
  :previous-hash sha256
  :event-hash sha256)
```

Campaign, benchmark, run, and task identifiers are nonempty ASCII strings.
The three configuration fields are SHA-256 values. A replicate index is a
positive integer. Run completion and task correctness are Boolean values.
Every source metric and budget is between zero and `10^20 - 1`, inclusive.

The accepted splits are `:feedback`, `:development`, `:selection`, and
`:held-out`. The first three values form the exposed split class.

Evaluation activation evidence uses this closed grammar:

```text
activation-evidence = activation-record*
activation-record = (
  :component string
  :kind (:runtime-hit | :reachable)
  :artifact-sha256 sha256)
```

The activation list SHALL contain unique records in ascending canonical-byte
order. Each activation record uses exactly the three keys shown above.

Incomplete final lines are ignored. Malformed complete lines are rejected.
The event hash covers canonical event content and the prior event hash.
Actor signatures cover canonical event content without signature or chain fields.
Run identifiers SHALL be unique across the ledger.

Each replayed evaluation SHALL reference a manifest with the same candidate
identifier. That manifest SHALL match a prior creator-signed freeze event by
candidate identifier and manifest digest. A separately valid manifest frozen
for another candidate SHALL NOT substitute for that historical manifest.
Every replayed freeze event SHALL resolve its candidate manifest. The computed
content identifier, creator signature, manifest digest, and lineage SHALL match
the signed freeze history, including histories with feedback-only evaluations.

Executor and evaluator signatures SHALL cover every evaluation field before
the signature and chain fields are added. A missing actor signature is malformed.

Ledger recognition SHALL reject a `(campaign-id, benchmark-id, task-id)` tuple
appearing in both split classes, regardless of candidate identifier.

One candidate SHALL contribute at most 256 held-out evaluation events to one
campaign. The 257th event is invalid before append.

Each complete ledger line SHALL contain at most 1 MiB of UTF-8 bytes. The
complete ledger SHALL contain at most 64 MiB of UTF-8 bytes. Append preflight
SHALL include the complete prefix, new event, and final newline. A projected
size above 64 MiB SHALL leave the ledger and signed head unchanged.

Every atomic write SHALL create its temporary peer exclusively with
`:if-exists :error`. A pre-existing entry at that peer path, including a hard
link, SHALL abort the replacement before any write. Bytes reachable through
the pre-existing entry SHALL remain unchanged.

Promotion and rollback events use this exact closed field order:

```text
pointer-event = (
  :event (:promotion | :rollback)
  :timestamp utc-string
  :candidate-id string
  :pointer (:canary | :active)
  :prior-candidate-id (string | nil)
  :evidence-head sha256
  :authorizer-did did-key
  :authorizer-signature ed25519-hex
  :seq positive-integer
  :previous-hash sha256
  :event-hash sha256)
```

The authorizer signature covers the pointer event before signature and chain
fields. Its payload includes `:evidence-head`. That digest SHALL equal the
immediately preceding ledger event hash.

Pointer files use this exact closed field order:

```text
pointer = (
  :version 1
  :pointer (:canary | :active)
  :candidate-id string
  :prior-candidate-id (string | nil)
  :event-hash sha256)
```

A pointer file SHALL match the latest signed event for its pointer name.
Deletion SHALL fail recognition when that signed event exists.

The store maintains a separate signed head containing the terminal sequence and
event hash. Every read SHALL compare the chain against that head. The store
authority signs each head without its signature field using Ed25519.

`read-ledger-head` SHALL validate the whole ledger and head correspondence
before returning the head. Store creation and append SHALL preflight a
self-verifying authority signature before any persistent mutation.

### CON-003 — Tool authorization

Dispatch selects exactly one authority branch:

```text
agent branch    = bound(*current-agent*)
                  AND registered(tool)
                  AND member(tool, current-agent.tools)
operator branch = unbound(*current-agent*)
                  AND bound(with-operator-tool-dispatch)
                  AND registered(tool)
otherwise       = deny
```

The `with-operator-tool-dispatch` macro is an exported API. It SHALL reject a
bound agent context. An unbound `*current-agent*` is necessary but insufficient
for direct operator dispatch.

`drive-stream` SHALL bind the supplied agent across frame handling and tool
dispatch. Nested synchronous dispatch retains that agent. A child thread that
does not inherit either dynamic scope takes the deny branch.

The `harness-eval` worker SHALL bind the originating agent during evaluation.
Self-modification recognition SHALL treat `*current-agent*`,
`*operator-tool-dispatch-p*`, `with-operator-tool-dispatch`, `handle-tool-frame`,
and `progv` as safety-layer symbols. The lift SHALL emit `mentions/2` for a
safety-layer symbol in any form position. This rule covers `let`, `let*`,
lambda-list, and other binding patterns at the reasoner fact seam.

Each evaluation worker SHALL install a closure-owned snapshot of its originating
tool allowlist for its synchronous dynamic extent. The snapshot SHALL contain
canonical registered symbol identities, not caller-owned mutable strings.
Dispatch SHALL consult it before dynamic agent or operator state. Calling
`drive-stream` with a constructed agent SHALL NOT widen the snapshot.

Before an agent's first evaluation, the closure SHALL record that agent's
canonical authority ceiling. Evaluation cleanup SHALL replace its visible
allowlist with the canonical intersection of that ceiling and its current
value. Later provider advertisement, ordinary dispatch, and evaluation SHALL
all use that reduced value. Evaluated slot mutation therefore does not widen a
later action, while an operator can still reduce authority. An operator who
needs wider evaluation or ordinary-dispatch authority SHALL construct a new
agent.

Allowlist canonicalization SHALL accept no more than 256 proper, acyclic list
cells. A dotted, cyclic, oversized, or otherwise malformed value SHALL reduce
to no authority without blocking cleanup. Cleanup SHALL remove the active
worker record even when slot sanitation signals. Evaluation values and
conditions SHALL be converted to bounded inert strings inside the worker while
its ceiling remains active. A nonce-bound mailbox result SHALL be accepted only
after that sanitation and record removal complete.

The snapshot lookup SHALL use the executing VM thread identity rather than the
dynamically bindable `sb-thread:*current-thread*` value. A nested installer
SHALL NOT widen, replace, or clear an active snapshot. No mutable snapshot
object is exposed to evaluated code.

This contract governs the provider call path. It is not an isolation boundary
against hostile Lisp running in the same process. Deliberately concealed thread
creation and detached child execution require an external process sandbox.
Frozen candidate evaluation uses that external boundary.

The self-modification enforcement TCB includes every named function or state
cell that decides parsing, prefiltering, lifting, fact installation, or queries.
It also includes proof recognition, dispatch membership, evaluation reachability,
mailbox result transport, audit recording, and safety-tool installation. The
named provider TCB includes request advertisement, response ingress, JSON
recognition, argument conversion, frame production, and dispatch-loop helpers.
It also includes endpoint, authentication, and configuration readers. Direct
environment readers and named process launchers belong to this boundary. It
covers credential accessors, credential erasers, clean-image entry points, and
their mutable bounds. Runtime lifecycle and MOP generics that can intercept object
construction or slot access are definition-protected. Recognition SHALL prevent an evaluated definition or
method that structurally names that TCB from replacing it. A rejected
replacement SHALL leave the next handler call fail-closed, and the next clean
pass SHALL still erase provider and signing credentials.

Runtime construction of a TCB target, generalized writer, or direct registry
access belongs to the hostile-Lisp limitation. Selected computed authority-state
cases in [[SPEC-014-harness-evolution-control-plane#TEST-065]] are additional
defense in depth. They do not establish a general reflective-code sandbox.

### CON-004 — Promotion gates

An eligible decision requires all conditions below:

```text
candidate digest valid
baseline digest valid
comparison-cell multisets match exactly
candidate comparison cells are unique
selected events use one evaluation-plan digest
replicate templates match
minimum complete held-out replicates met
minimum distinct executors met
every baseline-correct cell has a correct candidate match
every changed candidate component has a manifest-bound runtime hit
every matched held-out event attests complete execution
all held-out evaluators differ from candidate creator
all held-out creator, executor, and evaluator identities are pairwise distinct
all held-out actor signatures verify against their configured trusted DIDs
minimum replicate capability delta meets the positive configured threshold
every matched executor-config capability delta meets that threshold
execution-token increase does not exceed its configured maximum
runtime-cost increase does not exceed its configured maximum
authorizer roster is disjoint from executor and evaluator rosters
decision authorizer differs from both compared creators
trusted authorizer signature verifies over the eligible decision
```

The decision report SHALL expose each condition independently.
The decision SHALL consume every valid held-out event for its campaign and
compared candidates at calculation time. Callers SHALL NOT select event rows.

Ledger replay SHALL re-derive each context-dependent gate and report value
from the signed evidence prefix. Candidate and baseline digest-valid gates are
signed point-in-time attestations during replay. This exception preserves
history after later image-byte corruption; it does not authorize promotion.
Decision creation and replay SHALL require both referenced candidates and all
of their ancestors to retain creator-signed manifests anchored to unique prior
freeze events. Missing historical context SHALL NOT become a cached false gate.

Capability and efficiency gates are separate conjunction terms. A passing
capability result SHALL NOT offset an efficiency failure.

Store construction SHALL reject pairwise trust-roster overlap before creating
or changing store files. It SHALL copy every configured DID string so later
mutation of the caller's lists or strings cannot change stored authority.

The decision records the evidence head and its own event hash. Its authorizer
signs the decision without its authorization signature. Promotion SHALL reject
the decision unless its event remains the current ledger head.

Promotion SHALL verify current candidate and baseline bytes independently of
the retained digest attestations. Rollback SHALL verify the recorded prior
candidate. It SHALL tolerate corrupt bytes in the current image only.
That exemption applies when the current candidate is an ancestor of the prior
candidate, while all manifest, freeze, lineage, and other image checks remain.
Promotion SHALL reject a transition to the pointer's current candidate.
Historical replay still requires every referenced manifest.

The defaults are three complete replicates and two distinct executors.
Implementations SHALL reject either count below two.

The capability threshold defaults to one millionth and SHALL be positive.
Each maximum increase defaults to zero and SHALL be nonnegative.

`make-decision!` SHALL accept a campaign identifier and the three thresholds.
It also accepts the two count minima and both compared candidate identifiers.

The signed decision event SHALL include the campaign identifier, thresholds,
gate map, metric report, evidence head, compared identifiers, and authorizer.

### CON-005 — Filesystem confinement

Candidate identifiers and pointer names SHALL match `[a-z0-9][a-z0-9-]{0,62}`.
Manifest image paths SHALL be relative basenames. Operations SHALL reject path
traversal before opening or creating a file.

### CON-006 — Canonical signed bytes

Every signed payload is a closed-schema property list with keys in contract
order. Nested property lists also use their declared contract order.

The recognizer accepts exactly this bounded grammar before returning an AST:

```text
input       = ws value ws EOF
value       = "nil" | "t" | keyword | integer | string | list | base-string
keyword     = ":" known-keyword
integer     = "0" | nonzero-digit *31DIGIT | "-" nonzero-digit *31DIGIT
string      = DQUOTE *65536(string-char | "\\\"" | "\\\\") DQUOTE
list        = "(" ws [value *(ws1 value)] ws ")"
base-string = "#A((" length ") common-lisp:base-char . " string ")"
ws          = *(SP | HTAB | CR | LF)
ws1         = 1*(SP | HTAB | CR | LF)
```

`known-keyword` belongs to the finite union of every closed persisted schema.
An integer has at most 32 decimal digits, excluding its optional sign.
Leading zeroes, negative zero, floats, ratios, dispatch syntax, and other
symbols are invalid. A list contains at most 4,096 values. Nesting depth is at
most 64, and one form contains at most 16,384 values.

Each complete form contains at most 1 MiB of UTF-8 bytes. The recognizer SHALL
measure encoded octets, not Common Lisp character count. Exactly 1 MiB passes
this size gate; one additional octet fails before AST allocation.

Source metrics and budgets use integers in `[0, 10^20 - 1]`. Derived decision
aggregates use the 32-digit grammar, so every admitted campaign remains
serializable. Capability scores use integer millionths. Costs use integer
micro-US dollars.

Manifest changed components and manifest activation evidence are sorted unique
string lists. Evaluation activation records follow [[SPEC-014-harness-evolution-control-plane#CON-002]].
Strings reject Unicode C0 and C1 controls, including U+007F through U+009F.
Identifiers and DIDs use their declared ASCII grammars.

The encoder binds `*package*` to `KEYWORD`, `*print-base*` to 10,
`*print-radix*` to `nil`, and `*print-case*` to `:downcase`. It also binds
`*print-pretty*` and `*print-circle*` to `nil`. It binds `*print-escape*` and
`*print-readably*` to `t`.

The writer recursively serializes lists and emits bare `nil` and `t` tokens.
It SHALL NOT emit package-qualified Boolean tokens. SBCL `prin1` emits each
other atom without trailing whitespace. UTF-8 encodes that exact text.

Before persistence, the writer SHALL prove recognizer equivalence by checking
`parse(serialize(value)) = value`. Property tests SHALL generate valid values
for round trips. Fuzz tests SHALL establish rejection or canonical idempotence
for arbitrary text without package or tool-registry mutation.

A valid actor DID starts with `did:key:z6Mk`. `parse-did-key` SHALL decode it to
exactly 32 Ed25519 public-key bytes. Signatures are lowercase hexadecimal for
exactly 64 signature bytes.

### CON-007 — Matched comparison methodology

A comparison uses all held-out evaluation events for one campaign and two
candidate identifiers. Each event maps to this comparison cell:

```text
comparison-cell = (
  :benchmark-id string
  :task-id string
  :replicate-index positive-integer
  :executor-did did-key
  :evaluator-did did-key
  :evaluation-plan-sha256 sha256
  :executor-config-sha256 sha256
  :scorer-config-sha256 sha256)
```

The candidate identifier and run identifier are not cell fields. Baseline and
candidate cell multisets SHALL be exactly equal. Candidate cells SHALL be
unique.

Each candidate and campaign pair SHALL contain at most 256 held-out events.
This bound applies during append and historical ledger replay.

Append and ledger recognition SHALL reject duplicate
`(campaign-id, candidate-id, comparison-cell)` tuples. The decision uniqueness
gate remains a defense-in-depth result.

Selected comparison events SHALL contain exactly one distinct
`:evaluation-plan-sha256` value.

Correctness retention compares events through their complete comparison cells.
Every baseline-correct cell SHALL have a correct matched candidate event.

A replicate template removes replicate index, executor DID, and evaluator DID
from each comparison cell. Every counted replicate SHALL have the same template.
Baseline and candidate actors still match within each complete comparison cell.
All counted events SHALL carry `:run-complete-p t`.

The held-out repetition count is the number of distinct complete replicate
indices. Event-row count SHALL NOT substitute for this value.
The count is zero when any selected replicate template differs.

The distinct executor count is the number of executor DIDs in the common cell
multiset. Each DID counts once across all replicate indices.

For each replicate, the report computes each side's capability mean across its
matched cells. The replicate delta is candidate mean minus baseline mean.

The report SHALL sort replicate delta records by ascending replicate index.
The conservative noise-adjusted delta is the minimum replicate delta.

For each matched executor and executor configuration, the report computes each
side's capability mean. The cohort delta is candidate mean minus baseline mean.

The report SHALL sort cohort records by executor DID, then configuration digest.
Every matched executor belongs to the configured executor roster.
Every distinct executor and configuration pair SHALL appear exactly once.

Candidate activation coverage is the union of candidate held-out activation
records. Every changed-component string SHALL equal a covered `:component`.
Each covering record SHALL use `:runtime-hit`. Its `:artifact-sha256` equals
the candidate manifest `:image-sha256`.
`:reachable` records remain signed diagnostics and do not satisfy coverage.

An integer mean is `truncate(sum / event-count)`. Execution tokens equal input
tokens plus output tokens for one event.

Each side's token total sums execution tokens across matched events. Each side's
cost total sums `:estimated-cost-microusd` across matched events.

Each per-event mean uses its side's total and event count. A signed delta is
the candidate value minus the baseline value.

Every persisted evaluation metric and candidate budget is at most
`10^20 - 1`. Derived totals, means, and signed deltas SHALL fit the
32-decimal-digit grammar in [[SPEC-014-harness-evolution-control-plane#CON-006]].

The decision event uses this exact closed field order:

```text
decision = (
  :event :decision
  :timestamp utc-string
  :candidate-id string
  :baseline-id string
  :campaign-id string
  :evidence-head sha256
  :minimum-held-out-repetitions integer-at-least-two
  :minimum-distinct-executors integer-at-least-two
  :minimum-capability-delta-micros positive-integer
  :maximum-execution-token-increase nonnegative-integer
  :maximum-runtime-cost-increase-microusd nonnegative-integer
  :gates gate-map
  :failed-gates ordered-gate-key-list
  :baseline-capability-mean-micros nonnegative-integer
  :candidate-capability-mean-micros nonnegative-integer
  :capability-delta-micros integer
  :replicate-capability-deltas replicate-delta-list
  :conservative-capability-delta-micros integer
  :executor-capability-deltas executor-delta-list
  :baseline-execution-tokens-total nonnegative-integer
  :candidate-execution-tokens-total nonnegative-integer
  :baseline-execution-tokens-mean-per-event nonnegative-integer
  :candidate-execution-tokens-mean-per-event nonnegative-integer
  :execution-token-delta integer
  :baseline-runtime-cost-microusd-total nonnegative-integer
  :candidate-runtime-cost-microusd-total nonnegative-integer
  :baseline-runtime-cost-microusd-mean-per-event nonnegative-integer
  :candidate-runtime-cost-microusd-mean-per-event nonnegative-integer
  :runtime-cost-delta-microusd integer
  :development-cost-microusd nonnegative-integer
  :eligible-p boolean
  :authorizer-did did-key
  :authorization-signature ed25519-hex
  :seq positive-integer
  :previous-hash sha256
  :event-hash sha256)

replicate-delta = (
  :replicate-index positive-integer
  :baseline-capability-mean-micros nonnegative-integer
  :candidate-capability-mean-micros nonnegative-integer
  :capability-delta-micros integer)

executor-delta = (
  :executor-did did-key
  :executor-config-sha256 sha256
  :baseline-capability-mean-micros nonnegative-integer
  :candidate-capability-mean-micros nonnegative-integer
  :capability-delta-micros integer)

gate-map = (
  :candidate-digest-valid boolean
  :baseline-digest-valid boolean
  :comparison-cells-match boolean
  :candidate-cells-unique boolean
  :single-evaluation-plan-context boolean
  :replicate-templates-match boolean
  :minimum-held-out-repetitions-met boolean
  :minimum-distinct-executors-met boolean
  :correctness-retained boolean
  :changed-components-activated boolean
  :runs-complete boolean
  :creator-evaluator-separated boolean
  :roles-pairwise-distinct boolean
  :trusted-actor-signatures boolean
  :replicate-capability-delta-met boolean
  :per-executor-config-capability-delta-met boolean
  :execution-token-increase-within-limit boolean
  :runtime-cost-increase-within-limit boolean
  :authorizer-rosters-disjoint boolean
  :authorizer-creators-separated boolean
  :trusted-authorizer-signature boolean)
```

The gate map follows the condition order in
[[SPEC-014-harness-evolution-control-plane#CON-004]]. Failed gates contain
exactly the false gate keys in that order.

### CON-008 — OpenRouter response grammar

The HTTP response body is untrusted input. The provider SHALL bound and fully
recognize it before emitting frames that can reach hooks or tool handlers.

The outer response is exactly one of these mutually exclusive forms:

```text
response       = success-envelope | error-envelope
success-envelope = object {
  required: "choices"
  optional: "id", "object", "created", "model", "usage",
            "system_fingerprint", "provider"
}
error-envelope = object {
  required: "error"
  optional: "id", "request_id"
}
error = object {
  required: "message"
  optional: "code", "metadata"
}
```

An envelope containing both `choices` and `error` is invalid. Every object with
enumerated fields below is closed. Unknown fields in those objects, duplicate
keys, missing required fields, and wrong JSON types are invalid.
The optional envelope identifiers are bounded strings or JSON null. Error
codes are strings, integers, or JSON null. Error metadata is an object or JSON
null. The error message is a string.

A success envelope contains exactly one choice. Root string metadata is a
string or JSON null. `created` is a nonnegative integer. `usage` uses only
these optional fields:

```text
usage = object {
  optional: "prompt_tokens", "completion_tokens", "total_tokens", "cost",
            "is_byok", "prompt_tokens_details", "completion_tokens_details"
}
prompt_tokens_details = object {
  optional: "cached_tokens", "audio_tokens", "video_tokens"
}
completion_tokens_details = object {
  optional: "reasoning_tokens", "audio_tokens",
            "accepted_prediction_tokens", "rejected_prediction_tokens"
}
```

Token counts and detail values are nonnegative integers. Cost is a
nonnegative JSON number or JSON null. `is_byok` is a JSON Boolean.
Each details field contains its named object or JSON null.

The sole choice and assistant message use these closed shapes:

```text
choice = object {
  required: "message", "finish_reason"
  optional: "index", "native_finish_reason", "logprobs"
}
message = object {
  required: "role", "content"
  optional: "tool_calls", "refusal", "reasoning"
}
```

`index` is a nonnegative integer. `native_finish_reason` is a string or JSON
null. `logprobs` accepts JSON null only. The role is exactly `assistant`.
Content, refusal, and reasoning accept a string or JSON null.

The finish reason is `stop`, `tool_calls`, `length`, or `error`. An unknown
finish reason produces a terminal error and no actionable tool frame. A
`tool_calls` finish requires between one and 16 calls. Every other finish
requires tool calls to be absent or an empty vector.

Each tool call uses this exact grammar:

```text
tool-call = object {
  required-only: "id", "type", "function"
}
function = object {
  required-only: "name", "arguments"
}
type      = "function"
id        = bounded-token-string(1, 256)
name      = bounded-token-string(1, 128)
arguments = JSON-text(UTF-8-octets <= 65536)
```

Tool-call identifiers SHALL be unique inside the response. The arguments text
SHALL parse as one JSON object. Its keys SHALL match the registered tool's
finite schema exactly, including required keys and declared value types.

Schema strings map to strings. Integers map to integers. Numbers map to JSON
numbers. Booleans map only to `t` or `nil`. Objects map to hash tables. Arrays
map only to vectors.

Jzon maps JSON true to `t`, JSON false to `nil`, and JSON null to `null`.
Nullable fields accept `null`, never `nil`. Boolean fields accept `t` or `nil`,
never `null`.

An unknown tool, unknown argument, missing argument, wrong type, or malformed
arguments text produces the unforgeable inert-arguments marker. The turn loop
converts that marker into a correlated error result before hooks or handlers.

The provider SHALL NOT intern response keys, tool names, or argument keys.
Tool names resolve only against the finite registry. Argument keys resolve
only against the selected tool schema.

Recognition enforces these ceilings before full JSON materialization:

| Resource | Ceiling |
|---|---:|
| HTTP response | 1 MiB of UTF-8 bytes |
| Tool arguments text | 64 KiB of UTF-8 bytes |
| JSON nesting depth | 32 |
| JSON nodes | 8,192 |
| Keys per object | 256 |
| Elements per array | 256 |
| Characters per string | 65,536 |
| Tool calls per response | 16 |
| Tool-call identifier characters | 256 |
| Tool-name characters | 128 |

A reported non-2xx HTTP status SHALL terminate with an error before body
semantics can emit tool frames. A syntactically valid body cannot override
that status.

## Threat boundary

The evolution store runs in an external evaluator process under operator-owned
filesystem permissions. Frozen candidate processes receive only copied image
bytes and task inputs. They do not receive the store path or private identities.

The ledger detects accidental or unauthorized edits within that boundary. It
does not defend against an operator who replaces both the ledger and its signed
head with a previously valid snapshot.

DIDs and signatures bind records to keys. Operators remain responsible for
signer-process isolation and private-key custody outside this subsystem.

Evaluation-plan digests bind exact bytes. External benchmark governance remains
responsible for plan content, sealed-task confidentiality, and task execution.

`:run-complete-p` is an external runner attestation. The control plane verifies
its signed value but does not execute or inspect the benchmark protocol.

Version 0.3 uses one writer per store. Multi-process writer coordination and
crash recovery remain external operational responsibilities.

These boundaries do not relax complete recognition, fail-closed ledger checks,
atomic pointer replacement, or [[SPEC-014-harness-evolution-control-plane#CON-005]].

OpenRouter response bytes cross a separate network trust boundary. The limits
and grammar in [[SPEC-014-harness-evolution-control-plane#CON-008]] apply before
provider data can reach agent hooks or tool dispatch.

## Observability

### OBS-001 — Candidate freeze event

The ledger records candidate, parent, image digest, manifest digest, and creator.

### OBS-002 — Evaluation event

The ledger records campaign, benchmark, protocol digests, actors, replicate,
completion, correctness, capability, activation, latency, tokens, and cost.

### OBS-003 — Decision event

The ledger records thresholds, gate results, matched-cell summaries, replicate
and executor-config deltas, efficiency totals, signed deltas, and eligibility.

### OBS-004 — Promotion event

The ledger records pointer, prior candidate, new candidate, and authorizer.

### OBS-005 — Runtime authorization failure

A forbidden tool call returns `:unauthorized` in the canonical tool result.

### OBS-006 — Reasoner failure

A reasoner error produces a vetoed result. The error does not authorize work.

### OBS-007 — Provider recognition failure

An invalid OpenRouter response produces a bounded canonical error and terminal
frame. It produces no actionable tool frame.

## Tests

### TEST-001 — Factory main-path integration

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-001]].
**Type:** positive integration.

Use a counting factory with echo and serve helpers. Verify the returned agent is
the factory product. Scaffold a project and verify its toplevel passes the factory.

### TEST-002 — OpenRouter two-step tool integration

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-002]].
**Type:** positive integration.

Stub two HTTP responses. Verify canonical history, one tool dispatch, one
tool-result request, assistant content preservation, and final text.

### TEST-003 — Dispatch allowlist denial

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-003]].
**Type:** negative input.

Register two tools. Give an agent one tool. Verify the other tool returns
`:unauthorized` and its handler remains untouched.

### TEST-004 — Reasoner outage denial

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-004]].
**Type:** prohibited action.

Make each reasoner seam signal. Verify invariant dispatch and `harness-eval`
both veto without evaluation.

### TEST-005 — Optional load boundary

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-005]],
[[SPEC-014-harness-evolution-control-plane#NFR-002]].
**Type:** scope invariant.

Load `imago` and verify evolution symbols are absent. Load `imago/evolution`
and verify they are present without registering tools.

### TEST-006 — Responsibility round trip

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-006]].
**Type:** positive persistence and cryptographic verification.

Freeze, evaluate, decide, and promote a candidate. Verify actor DIDs and
signatures survive persistence and validate after reload.

### TEST-007 — Freeze immutability

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-007]].
**Type:** negative input.

Freeze an image twice. Verify the first succeeds and the second cannot overwrite
candidate files.

### TEST-008 — Parent verification

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-008]].
**Type:** negative input.

Freeze a root and child. Tamper with the recorded parent digest. Verify the
child fails validation.

### TEST-009 — Surface manifest completeness

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-009]].
**Type:** negative input.

Omit each required surface field in turn. Verify complete rejection before
candidate creation.

### TEST-010 — Append-only ledger

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-010]].
**Type:** positive persistence.

Record every event kind. Verify sequence preservation and malformed complete
entry rejection.

### TEST-011 — Role separation

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-011]].
**Type:** negative input.

Reuse any actor across held-out roles. Verify record rejection. Use three
distinct identities and verify acceptance only for a trusted evaluator.

### TEST-012 — Correctness gate

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-012]].
**Type:** negative output.

Make the candidate regress on one baseline-correct cell. Verify ineligibility
despite a higher capability mean.

### TEST-013 — Repetition matrix gate

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-013]].
**Type:** boundary analysis.

Vary repetitions and executor identities around each threshold. Verify both
boundaries independently.

### TEST-014 — Metric separation

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-014]].
**Type:** positive output.

Record one run. Verify capability, activation, duration, tokens, and cost remain
distinct report fields.

### TEST-015 — External authorization gate

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-015]].
**Type:** negative input.

Pass an eligible decision with untrusted and trusted authorizer identities.
Verify only the trusted signature changes a pointer.

### TEST-016 — Canary rollback

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-016]].
**Type:** positive integration.

Promote two canaries and roll back once. Verify the pointer returns to the first
candidate. Verify both promotions and the rollback remain in the ledger.

### TEST-017 — Tamper detection

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-017]].
**Type:** prohibited action.

Change one byte in a frozen image. Verify candidate validation and promotion fail.

### TEST-018 — Baseline-relative metrics

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-018]].
**Type:** positive output.

Record shuffled baseline and candidate runs. Verify stable means, capability
delta, runtime cost, and development cost.

### TEST-019 — Deterministic candidate identity

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-001]].
**Type:** positive property.

Freeze identical bytes with identical identity inputs in separate stores. Verify
equal candidate identifiers.

### TEST-020 — Missing-gate diagnostics

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-003]].
**Type:** negative output.

Request a decision with no evaluations. Verify all unmet gates are listed.

### TEST-021 — Reader attack corpus

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-004]].
**Type:** negative input.

Feed `#.` forms, extra forms, unknown keys, traversal names, malformed digests,
and truncated lines. Verify no payload executes and no pointer changes.

### TEST-022 — Factory scope invariant

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-001]].
**Type:** scope invariant.

Run a custom factory once. Verify no default agent starts and no second factory
invocation occurs.

### TEST-023 — Malformed provider frames

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-002]].
**Type:** negative input.

Return malformed tool arguments and an unknown finish reason. Verify one error
result, no handler call, and preserved valid history.

### TEST-024 — Authorized dispatch

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-003]].
**Type:** positive and scope invariant.

Advertise and call one allowed tool. Verify exactly that handler runs once and
no other registered handler runs.

### TEST-025 — Malformed reasoner evidence

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-004]].
**Type:** negative input and prohibited action.

Return missing and unknown proof tags. Verify both guarded paths veto and their
protected handlers remain untouched.

### TEST-026 — Freeze filesystem scope invariant

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-007]],
[[SPEC-014-harness-evolution-control-plane#CON-002]],
[[SPEC-014-harness-evolution-control-plane#CON-005]].
**Type:** prohibited action and scope invariant.

Attempt collision, traversal, and symlink targets. Verify prior candidate bytes,
the ledger prefix, and all paths outside the store remain unchanged. Pre-create
an atomic temporary peer as a hard link to an outside sentinel. Verify the
write rejects the collision and preserves the sentinel bytes.

### TEST-027 — Ledger chain integrity

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-010]].
**Type:** negative input and scope invariant.

Modify, delete, reorder, and truncate historical events. Verify chain validation
rejects each complete corruption and never changes the ledger or pointers.
Verify `read-ledger-head` rejects every ledger and head mismatch.

### TEST-028 — Promotion prohibited actions

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-015]].
**Type:** prohibited action.

Try an ineligible decision, an untrusted authorizer, and an agent-context call.
Verify no pointer or promotion event appears.

### TEST-029 — Pointer scope invariant

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-016]].
**Type:** scope invariant.

Update each supported pointer. Verify other pointers and every candidate byte
remain unchanged. Verify readers observe either the old or new complete form.

### TEST-030 — Valid reader round trip

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-004]].
**Type:** positive and scope invariant.

Read valid manifests, events, and pointers. Verify exact decoded values and no
filesystem, registry, or pointer mutation.

### TEST-031 — Decision order property

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-001]].
**Type:** positive property.

Shuffle identical evaluation events repeatedly. Verify equal gate results,
means, deltas, costs, and eligibility.

### TEST-032 — Valid lineage round trip

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-008]].
**Type:** positive persistence.

Freeze a root and child. Verify the child records the root identifier and exact
root digest, then validates without changing either candidate.

### TEST-033 — Signed-byte interoperability

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-006]],
[[SPEC-014-harness-evolution-control-plane#CON-006]].
**Type:** positive property and negative input.

Sign fixed manifest, event, decision, and head fixtures. Verify stable payload
bytes and signatures. Reject non-Ed25519 DIDs and malformed signatures.

### TEST-034 — Run replay and stale decision

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-010]],
[[SPEC-014-harness-evolution-control-plane#REQ-018]].
**Type:** negative input and prohibited action.

Append a duplicate run identifier and verify rejection. Substitute a separately
valid signed manifest from another frozen candidate and verify replay fails.
Delete and corrupt the manifest after a lone freeze and after feedback-only
evaluation. Verify ledger replay fails until the exact manifest is restored.
Append evidence after a decision, then verify the stale decision cannot change
a pointer.

### TEST-035 — Disjoint role rosters

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-011]].
**Type:** negative input.

Configure overlapping executor and evaluator rosters. Verify store creation
fails. Use disjoint rosters and verify only enrolled identities can attest.

### TEST-036 — Signed protocol envelope

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-019]],
[[SPEC-014-harness-evolution-control-plane#CON-002]].
**Type:** negative input and positive persistence.

Record a complete signed evaluation envelope. Verify every protocol field and
both signatures survive reload. Omit each added field in turn. Use a zero
replicate index, malformed configuration digest, and altered signature.
Verify rejection before the event changes decision evidence.

### TEST-037 — Unmatched comparison cells

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-020]],
[[SPEC-014-harness-evolution-control-plane#CON-007]].
**Type:** negative output.

Change each comparison-cell dimension on one candidate row. Verify every
variant is ineligible through `:comparison-cells-match`.

### TEST-038 — Duplicate candidate cells

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-021]].
**Type:** negative output and boundary analysis.

Give candidate rows distinct run identifiers but identical comparison cells.
Verify the second append fails and the ledger remains unchanged. Verify unique
cells pass `:candidate-cells-unique` during decision calculation.

### TEST-039 — Campaign split contamination

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-022]].
**Type:** negative input and prohibited action.

Record one benchmark-task pair in an exposed split. Attempt its held-out reuse
in that campaign. Verify no ledger append. Repeat across candidates in reverse
order. Verify the same task under another benchmark remains valid.

### TEST-040 — Complete replicate counting

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-013]],
[[SPEC-014-harness-evolution-control-plane#REQ-023]].
**Type:** boundary analysis.

Supply many rows for one replicate. Verify they count once. Change one later
replicate template. Verify its template gate and minimum-repetition gate fail.

### TEST-041 — Conservative replicate noise gate

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-024]].
**Type:** negative output and boundary analysis.

Make the pooled capability delta pass while one replicate delta misses the
positive threshold. Verify ineligibility. Exercise equality at the threshold.

### TEST-042 — Separated efficiency report

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-014]],
[[SPEC-014-harness-evolution-control-plane#REQ-025]].
**Type:** positive output.

Use equal matched counts with unequal per-event resource values. Verify token
totals, integer means, runtime-cost totals, cost means, and signed deltas.

### TEST-043 — Execution-token increase gate

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-026]].
**Type:** negative output and boundary analysis.

Set cost and capability gates to pass. Move execution-token delta below, at,
and above its maximum. Verify only the above-maximum case fails its gate.

### TEST-044 — Runtime-cost increase gate

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-027]].
**Type:** negative output and boundary analysis.

Set token and capability gates to pass. Move runtime-cost delta below, at, and
above its maximum. Verify only the above-maximum case fails its gate.

### TEST-045 — Per-executor-config transfer

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-028]].
**Type:** negative output and positive property.

Make the pooled delta pass while one executor-config cohort regresses. Verify
ineligibility. Shuffle event order and verify identical sorted cohort records.

### TEST-046 — Changed-component activation coverage

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-029]],
[[SPEC-014-harness-evolution-control-plane#CON-002]].
**Type:** negative input and negative output.

Reject unsorted, duplicate, unknown-kind, and extra-key activation records.
Use reachable-only and wrong-candidate-digest records. Verify neither satisfies
coverage. Then omit one changed component and verify the same isolated failure.

### TEST-047 — Complete-run attestation

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-030]].
**Type:** negative output and prohibited action.

Set one matched event's `:run-complete-p` to `nil`. Verify the completion gate
fails and promotion remains unchanged despite passing score and cost gates.

### TEST-048 — Authorizer roster separation

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-031]].
**Type:** negative input and scope invariant.

Configure an authorizer DID in either actor roster. Verify store creation
fails without files. Configure three disjoint rosters and verify acceptance.

### TEST-049 — Creator-authorizer separation

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-032]].
**Type:** prohibited action.

Authorize with either compared creator while retaining valid signatures.
Verify `:authorizer-creators-separated` fails and no pointer changes.

### TEST-050 — Single evaluation-plan context

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-033]].
**Type:** negative output.

Give both sides matching cells from two evaluation-plan digests. Verify
`:single-evaluation-plan-context` fails while cell matching remains true.

### TEST-051 — Direct stream authority

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-003]],
[[SPEC-014-harness-evolution-control-plane#CON-003]].
**Type:** prohibited action.

Call `drive-stream` directly with a provider-requested tool outside the supplied
agent allowlist. Verify the handler remains untouched and the result is
`:unauthorized`.

### TEST-052 — Cross-thread default denial

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-003]],
[[SPEC-014-harness-evolution-control-plane#REQ-004]],
[[SPEC-014-harness-evolution-control-plane#CON-003]].
**Type:** prohibited action and scope invariant.

Start a child thread inside a bound agent dispatch. Do not establish an
operator scope there. Verify hidden dispatch is unauthorized and no handler
runs. Then verify an explicit unbound operator scope can dispatch directly.

### TEST-053 — Persisted decision re-derivation

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-010]],
[[SPEC-014-harness-evolution-control-plane#REQ-018]],
[[SPEC-014-harness-evolution-control-plane#CON-004]].
**Type:** negative input and prohibited action.

Tamper with a signed decision's development cost and re-sign its actor and
chain fields. Verify ledger replay rejects the semantic mismatch and promotion
does not create a pointer. Corrupt later candidate image bytes and verify the
untampered historical decision remains readable.

### TEST-054 — Self-modification fact-seam failure

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-004]].
**Type:** prohibited action.

Make assertion and retraction calls fail independently around a valid negative
query result. Verify `harness-eval` never evaluates the form and returns a
vetoed result for each failure.

### TEST-055 — Safety-fact installation failure

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-004]].
**Type:** prohibited action and scope invariant.

Make safety-fact setup fail during self-modification installation. Verify no
guarded tool remains registered, no evaluation permission remains enabled, and
no protected handler runs.

### TEST-056 — Ledger projected-size preflight

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-010]],
[[SPEC-014-harness-evolution-control-plane#NFR-004]],
[[SPEC-014-harness-evolution-control-plane#CON-002]].
**Type:** boundary and scope invariant.

Set the ledger ceiling below the next event's projected UTF-8 size. Verify
append rejection leaves the ledger bytes and signed head exactly unchanged.

### TEST-057 — Unicode control rejection

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-004]],
[[SPEC-014-harness-evolution-control-plane#CON-006]].
**Type:** negative input.

Place U+0085 in a signed string field. Verify candidate freeze rejects the
value before candidate or ledger mutation.

### TEST-058 — Rollback after current-image corruption

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-016]],
[[SPEC-014-harness-evolution-control-plane#CON-004]].
**Type:** recovery integration.

Promote two candidates and corrupt only the current image bytes. Verify ledger
history remains readable. Verify rollback accepts the signed current pointer,
verifies the prior candidate, and restores that prior candidate. Repeat with
the prior candidate descending from the corrupt current candidate. Verify a
no-op promotion to the current candidate is rejected before append.

### TEST-059 — Pointer deletion denial

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-016]],
[[SPEC-014-harness-evolution-control-plane#CON-002]].
**Type:** prohibited action and scope invariant.

Delete a pointer after its signed promotion event. Verify reads and later
promotion fail. Verify ledger and head bytes remain unchanged, and no missing
file becomes a never-promoted state.

### TEST-060 — Authority signing preflight

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-006]],
[[SPEC-014-harness-evolution-control-plane#REQ-010]],
[[SPEC-014-harness-evolution-control-plane#CON-002]].
**Type:** prohibited action and scope invariant.

Clear or mismatch the authority private key. Verify fresh-store creation leaves
no ledger component. Verify append failure leaves candidate entries, ledger,
and head bytes unchanged. Verify every prepared head self-verifies.

### TEST-061 — Pointer evidence-head authorization

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-006]],
[[SPEC-014-harness-evolution-control-plane#REQ-016]],
[[SPEC-014-harness-evolution-control-plane#CON-002]].
**Type:** negative input and prohibited action.

Capture a valid signed rollback event, advance the ledger, and replay its actor
payload at the new head. Verify rejection, unchanged pointer, and unchanged
ledger length.

### TEST-062 — Aggregate serialization bounds

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-004]],
[[SPEC-014-harness-evolution-control-plane#CON-002]],
[[SPEC-014-harness-evolution-control-plane#CON-006]],
[[SPEC-014-harness-evolution-control-plane#CON-007]].
**Type:** positive property and boundary analysis.

Use source metrics at `10^20 - 1` and derive totals above that value. Verify the
decision round trip succeeds under the 32-digit grammar. Reject `10^20` as a
source metric. Admit the 256th held-out event and reject the 257th.

### TEST-063 — Closed persisted-parser properties

**Validates:** [[SPEC-014-harness-evolution-control-plane#NFR-004]],
[[SPEC-014-harness-evolution-control-plane#CON-006]].
**Type:** property, fuzz, and boundary analysis.

Generate 1,000 valid grammar values. Verify `parse(serialize(value)) = value`.
Feed 1,000 arbitrary strings and verify rejection or canonical idempotence.
Verify tools, packages, and symbol registries remain unchanged. Verify a form
and ledger line of exactly 1 MiB pass their octet gates. Verify one additional
octet fails each gate.

### TEST-064 — Closed OpenRouter response grammar

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-034]],
[[SPEC-014-harness-evolution-control-plane#CON-008]].
**Type:** negative input, fuzz, and prohibited action.

Exercise every required field, type, duplicate, unknown-field, schema, status,
and size boundary in [[SPEC-014-harness-evolution-control-plane#CON-008]]. Verify
16 calls pass and 17 fail. Feed 500 deterministic arbitrary bodies. Verify no
invalid body reaches a handler or interns a provider-controlled name.

Use positive and one-over fixtures for every numeric ceiling. Cover depth 32/33,
nodes 8,192/8,193, object keys 256/257, and array elements 256/257. Cover string
characters and argument octets at 65,536/65,537. Cover identifier characters at
256/257 and tool-name characters at 128/129. Verify HTTP 200 and 299 admit
recognized data. Statuses 199 and 300 cannot emit an actionable frame.

### TEST-065 — Evaluated operator-authority denial

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-003]],
[[SPEC-014-harness-evolution-control-plane#CON-003]].
**Type:** prohibited action and scope invariant.

Register a hidden tool outside the calling agent allowlist. Submit operator
scope and authority-state binding attempts through `%harness-eval-handler`.
Submit a macro definition that constructs the protected symbols from strings.
Invoke it through a second handler call. Submit a one-form variant that resolves
and calls the same symbols dynamically. Repeat a fake-agent `drive-stream`
attempt in the evaluation worker. Mutate a caller-owned string after snapshot
installation. Rebind Lisp's current-thread value without changing the VM thread.
Verify no synchronous variant reaches the hidden handler.

Use a computed generalized writer to widen the originating agent slot. On a
second handler call and an ordinary provider path, verify the first recorded
per-agent ceiling still denies the added tool. Verify advertisement omits it.
Verify a legitimate reduction of the current allowlist remains effective. Set
the slot to dotted and cyclic lists. Verify bounded cleanup publishes a
deterministic result and clears the raw slot. Verify it removes worker authority
and leaves later evaluation and dispatch usable but closed.

Attempt to forge mailbox receipt before worker cleanup. Return an object with a
trusted test printer that mutates the raw slot. Verify nonce validation rejects
forged transport, value and condition printing occurs inside the worker, and
the final visible allowlist is sanitized before return.

Attempt direct sequential replacements of the agent accessor, dispatch
membership helpers, pipeline stages, and lift and reasoner helpers. Repeat for
proof recognizers, the evaluator, mailbox paths, and audit paths. Cover provider
request builders, response recognizers, frame producers, and JSON parser seams.
Cover provider endpoint, authentication, and configuration readers. Attempt
direct environment reads and named child-process launchers. Cover credential
erasers, clean-image entry points, runtime lifecycle/MOP generics,
class/structure targets, and the installer. Each form structurally names its
target. Test delayed provider/build methods and a response-to-frame replacement
capable of synthesizing an authorized call. After each rejection, submit a
protected probe with a failed or malformed reasoner response. Verify no side
effect occurs. Then issue an ordinary provider request and clean pass; verify the
endpoint is unchanged and both provider and signing keys are erased. Mechanically
verify the expected authorization helper and ingress symbols are present in the
safety set. Finally, verify a direct call outside agent evaluation succeeds.

Append reader-evaluation syntax, an unknown symbol token, and a record whose
union-vocabulary key substitutes for a required schema key. Verify inspection,
query, and sequence recovery fail closed without evaluation or interning. Cover
receipt node/string boundaries, including escaped string characters. Cover
writer-reader closure for cyclic/foreign evidence and UTF-8 result truncation.
Verify sequence publication occurs only after a successful durable write.

### TEST-066 — Evaluation requires a prior freeze

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-010]],
[[SPEC-014-harness-evolution-control-plane#CON-002]].
**Type:** replay-order invariant and prohibited action.

For each of `:feedback`, `:development`, `:selection`, and `:held-out`, create a
creator-signed freeze followed by an executor/evaluator-signed evaluation.
Reorder the evaluation before the freeze, recompute only the ledger chain fields
and authority-signed head, and retain the original valid actor signatures.
Verify replay rejects every reordered ledger because the matching freeze is not
strictly prior to its evaluation.

## Traceability matrix

| Requirement | Verification | Control or observation |
|---|---|---|
| [[SPEC-014-harness-evolution-control-plane#REQ-001]] | [[SPEC-014-harness-evolution-control-plane#TEST-001]] | main-path activation |
| [[SPEC-014-harness-evolution-control-plane#REQ-002]] | [[SPEC-014-harness-evolution-control-plane#TEST-002]], [[SPEC-014-harness-evolution-control-plane#TEST-023]] | canonical provider frames |
| [[SPEC-014-harness-evolution-control-plane#REQ-003]] | [[SPEC-014-harness-evolution-control-plane#TEST-003]], [[SPEC-014-harness-evolution-control-plane#TEST-024]], [[SPEC-014-harness-evolution-control-plane#TEST-051]], [[SPEC-014-harness-evolution-control-plane#TEST-052]], [[SPEC-014-harness-evolution-control-plane#TEST-065]] | [[SPEC-014-harness-evolution-control-plane#CON-003]], [[SPEC-014-harness-evolution-control-plane#OBS-005]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-004]] | [[SPEC-014-harness-evolution-control-plane#TEST-004]], [[SPEC-014-harness-evolution-control-plane#TEST-025]], [[SPEC-014-harness-evolution-control-plane#TEST-054]], [[SPEC-014-harness-evolution-control-plane#TEST-055]], [[SPEC-014-harness-evolution-control-plane#TEST-065]] | [[SPEC-014-harness-evolution-control-plane#OBS-006]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-005]] | [[SPEC-014-harness-evolution-control-plane#TEST-005]] | [[SPEC-014-harness-evolution-control-plane#NFR-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-006]] | [[SPEC-014-harness-evolution-control-plane#TEST-006]], [[SPEC-014-harness-evolution-control-plane#TEST-036]], [[SPEC-014-harness-evolution-control-plane#TEST-060]], [[SPEC-014-harness-evolution-control-plane#TEST-061]] | [[SPEC-014-harness-evolution-control-plane#OBS-001]] through [[SPEC-014-harness-evolution-control-plane#OBS-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-007]] | [[SPEC-014-harness-evolution-control-plane#TEST-007]], [[SPEC-014-harness-evolution-control-plane#TEST-026]] | [[SPEC-014-harness-evolution-control-plane#CON-001]], [[SPEC-014-harness-evolution-control-plane#CON-002]], [[SPEC-014-harness-evolution-control-plane#CON-005]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-008]] | [[SPEC-014-harness-evolution-control-plane#TEST-008]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-009]] | [[SPEC-014-harness-evolution-control-plane#TEST-009]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-010]] | [[SPEC-014-harness-evolution-control-plane#TEST-010]], [[SPEC-014-harness-evolution-control-plane#TEST-027]], [[SPEC-014-harness-evolution-control-plane#TEST-053]], [[SPEC-014-harness-evolution-control-plane#TEST-056]], [[SPEC-014-harness-evolution-control-plane#TEST-060]], [[SPEC-014-harness-evolution-control-plane#TEST-066]] | [[SPEC-014-harness-evolution-control-plane#CON-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-011]] | [[SPEC-014-harness-evolution-control-plane#TEST-011]], [[SPEC-014-harness-evolution-control-plane#TEST-035]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-012]] | [[SPEC-014-harness-evolution-control-plane#TEST-012]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-013]] | [[SPEC-014-harness-evolution-control-plane#TEST-013]], [[SPEC-014-harness-evolution-control-plane#TEST-040]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-014]] | [[SPEC-014-harness-evolution-control-plane#TEST-014]], [[SPEC-014-harness-evolution-control-plane#TEST-042]] | [[SPEC-014-harness-evolution-control-plane#OBS-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-015]] | [[SPEC-014-harness-evolution-control-plane#TEST-015]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-016]] | [[SPEC-014-harness-evolution-control-plane#TEST-016]], [[SPEC-014-harness-evolution-control-plane#TEST-029]], [[SPEC-014-harness-evolution-control-plane#TEST-058]], [[SPEC-014-harness-evolution-control-plane#TEST-059]], [[SPEC-014-harness-evolution-control-plane#TEST-061]] | [[SPEC-014-harness-evolution-control-plane#OBS-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-017]] | [[SPEC-014-harness-evolution-control-plane#TEST-017]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-018]] | [[SPEC-014-harness-evolution-control-plane#TEST-018]], [[SPEC-014-harness-evolution-control-plane#TEST-053]] | [[SPEC-014-harness-evolution-control-plane#OBS-003]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-019]] | [[SPEC-014-harness-evolution-control-plane#TEST-036]] | [[SPEC-014-harness-evolution-control-plane#CON-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-020]] | [[SPEC-014-harness-evolution-control-plane#TEST-037]] | [[SPEC-014-harness-evolution-control-plane#CON-007]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-021]] | [[SPEC-014-harness-evolution-control-plane#TEST-038]] | [[SPEC-014-harness-evolution-control-plane#CON-007]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-022]] | [[SPEC-014-harness-evolution-control-plane#TEST-039]] | [[SPEC-014-harness-evolution-control-plane#CON-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-023]] | [[SPEC-014-harness-evolution-control-plane#TEST-040]] | [[SPEC-014-harness-evolution-control-plane#CON-007]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-024]] | [[SPEC-014-harness-evolution-control-plane#TEST-041]] | [[SPEC-014-harness-evolution-control-plane#CON-004]], [[SPEC-014-harness-evolution-control-plane#CON-007]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-025]] | [[SPEC-014-harness-evolution-control-plane#TEST-042]] | [[SPEC-014-harness-evolution-control-plane#OBS-003]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-026]] | [[SPEC-014-harness-evolution-control-plane#TEST-043]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-027]] | [[SPEC-014-harness-evolution-control-plane#TEST-044]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-028]] | [[SPEC-014-harness-evolution-control-plane#TEST-045]] | [[SPEC-014-harness-evolution-control-plane#CON-007]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-029]] | [[SPEC-014-harness-evolution-control-plane#TEST-046]] | [[SPEC-014-harness-evolution-control-plane#CON-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-030]] | [[SPEC-014-harness-evolution-control-plane#TEST-047]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-031]] | [[SPEC-014-harness-evolution-control-plane#TEST-048]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-032]] | [[SPEC-014-harness-evolution-control-plane#TEST-049]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-033]] | [[SPEC-014-harness-evolution-control-plane#TEST-050]] | [[SPEC-014-harness-evolution-control-plane#CON-004]], [[SPEC-014-harness-evolution-control-plane#CON-007]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-034]] | [[SPEC-014-harness-evolution-control-plane#TEST-023]], [[SPEC-014-harness-evolution-control-plane#TEST-064]] | [[SPEC-014-harness-evolution-control-plane#CON-008]], [[SPEC-014-harness-evolution-control-plane#OBS-007]] |
| [[SPEC-014-harness-evolution-control-plane#NFR-001]] | [[SPEC-014-harness-evolution-control-plane#TEST-019]], [[SPEC-014-harness-evolution-control-plane#TEST-031]], [[SPEC-014-harness-evolution-control-plane#TEST-045]] | content addressing and ordered reports |
| [[SPEC-014-harness-evolution-control-plane#NFR-002]] | [[SPEC-014-harness-evolution-control-plane#TEST-005]] | optional subsystem boundary and CI LOC budget |
| [[SPEC-014-harness-evolution-control-plane#NFR-003]] | [[SPEC-014-harness-evolution-control-plane#TEST-020]] | decision gate map |
| [[SPEC-014-harness-evolution-control-plane#NFR-004]] | [[SPEC-014-harness-evolution-control-plane#TEST-021]], [[SPEC-014-harness-evolution-control-plane#TEST-030]], [[SPEC-014-harness-evolution-control-plane#TEST-056]], [[SPEC-014-harness-evolution-control-plane#TEST-057]], [[SPEC-014-harness-evolution-control-plane#TEST-062]], [[SPEC-014-harness-evolution-control-plane#TEST-063]], [[SPEC-014-harness-evolution-control-plane#TEST-064]], [[SPEC-014-harness-evolution-control-plane#TEST-065]], [[SPEC-014-harness-evolution-control-plane#TEST-066]] | [[SPEC-014-harness-evolution-control-plane#CON-001]], [[SPEC-014-harness-evolution-control-plane#CON-002]], [[SPEC-014-harness-evolution-control-plane#CON-003]], [[SPEC-014-harness-evolution-control-plane#CON-005]], [[SPEC-014-harness-evolution-control-plane#CON-006]], [[SPEC-014-harness-evolution-control-plane#CON-008]] |

## Amendment channels

- New candidate fields require a versioned [[SPEC-014-harness-evolution-control-plane#CON-001]] amendment.
- New evidence events require a versioned [[SPEC-014-harness-evolution-control-plane#CON-002]] amendment.
- Comparison semantics require a versioned [[SPEC-014-harness-evolution-control-plane#CON-007]] amendment.
- Provider response fields or limits require a versioned [[SPEC-014-harness-evolution-control-plane#CON-008]] amendment.
- Promotion threshold values remain validated runtime policy inputs.
- New automatic mutation or promotion behavior requires a new specification.
- Runtime policy SHALL NOT waive roster separation, signed evidence, complete
  matching, fail-closed recognition, explicit dispatch authority, or filesystem
  confinement.

## Non-goals

- This version does not generate mutations.
- This version does not reveal held-out task content to creators.
- This version does not choose providers or models.
- This version does not add closed, bounded recognition to the Anthropic
  provider; [[SPEC-014-harness-evolution-control-plane#CON-008]] applies only
  to OpenRouter.
- This version does not claim autonomous recursive improvement.
- This version does not replace an external benchmark runner.
- This version does not verify evaluation-plan quality or task confidentiality.
- This version does not prove signer processes hold separate key custody.
- This version does not coordinate multiple store writers.
- This version does not repair a complete ledger event whose head update was interrupted.

## Gate evidence record

| Gate | Required evidence | Status |
|---|---|---|
| Specification lint | `usdd-lint.sh --type descriptive --strict` reports zero errors and warnings | pass |
| Reference integrity | `zetl check --syntax` and source-filtered dead-link output report zero SPEC-014 issues | pass |
| Comprehension | fresh-context version 0.3 review | pass; see `architecture/SPEC-014-REVIEW.md` |
| Fresh adversarial remediation | independent reviewer rechecks TEST-051 through TEST-065 | pass; six review cycles closed |
| Independent final approval | reviewer identity and explicit approval verdict | pass; `final-adversarial-review` approved `e48ffe9` |
| Red Gate | recorded failures before each review remediation | pass; every reproduced bypass gained a regression |
| Implementation | targeted and full test output for version 0.3 | pass; closure suite includes M1 through M12 and evolution |
| Theory closure | Elephant task evidence and final fingerprint | pass; `verified spec-014` derives after the final green assertion |

## References

- HarnessDev, arXiv:2609.01437, <https://arxiv.org/abs/2609.01437>.
- [[SPEC-012-self-modification-port]].
- [[SPEC-013-skill-definition-port]].

## Changelog

<details>
<summary>Revision history — 0.1.0 to 0.3.0</summary>

- 0.3.0 — Closes dispatch and provider grammars, re-derives persisted
  decisions, bounds persistence, and hardens pointer recovery.
- 0.2.0 — Adds matched protocol replicates, transfer gates, activation binding,
  efficiency limits, campaign isolation, and independent authorization.
- 0.1.1 — Defines exact fail-closed proof-result grammar.
- 0.1.0 — Establishes the signed evolution control plane.

</details>
