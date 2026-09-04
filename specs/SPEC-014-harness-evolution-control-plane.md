---
id: SPEC-014
title: Harness Evolution Control Plane
status: approved
version: 0.1.1
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
- Evolution remains an optional ASDF subsystem.
- Runtime safety defects block trustworthy evolution measurements.

**Load-bearing requirements:**

- [[SPEC-014-harness-evolution-control-plane#REQ-001]] fixes the custom-agent entrypoint.
- [[SPEC-014-harness-evolution-control-plane#REQ-002]] restores provider tool loops.
- [[SPEC-014-harness-evolution-control-plane#REQ-003]] enforces agent tool authority.
- [[SPEC-014-harness-evolution-control-plane#REQ-004]] makes invariant failures deny actions.
- [[SPEC-014-harness-evolution-control-plane#REQ-007]] freezes content-addressed candidates.
- [[SPEC-014-harness-evolution-control-plane#REQ-011]] separates evaluation roles.
- [[SPEC-014-harness-evolution-control-plane#REQ-015]] keeps promotion external.

**Controls:**

- [[SPEC-014-harness-evolution-control-plane#CON-001]] defines candidate manifest grammar.
- [[SPEC-014-harness-evolution-control-plane#CON-002]] defines append-only evidence grammar.
- [[SPEC-014-harness-evolution-control-plane#CON-003]] defines authorization checks.
- [[SPEC-014-harness-evolution-control-plane#CON-004]] defines promotion gates.
- [[SPEC-014-harness-evolution-control-plane#CON-005]] defines filesystem confinement.
- [[SPEC-014-harness-evolution-control-plane#CON-006]] defines signed bytes.

**Open items:** None for version 0.1. Deferred work appears under Non-goals.

**Detail:** Requirements start at
[[SPEC-014-harness-evolution-control-plane#Functional requirements]].
Verification starts at [[SPEC-014-harness-evolution-control-plane#Tests]].

## Context

[[SPEC-012-self-modification-port]] permits controlled changes inside a live
SBCL image. A saved image can preserve those changes across boots.

HarnessDev shows that mutation alone does not establish improvement.
Useful evolution needs frozen candidates, role separation, repeated evaluation,
held-out tasks, activation evidence, and explicit cost accounting.

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
4. The evaluator records activation evidence and resource use.
5. The evidence ledger appends the completed run.
6. The creator receives aggregate results only.

### HP-003 — Compare across executors

1. The evaluator repeats the unchanged baseline.
2. The evaluator repeats the candidate on identical task identifiers.
3. At least two executor identities run held-out trials.
4. The decision report computes capability and cost deltas.
5. Noise or failed correctness keeps the candidate ineligible.

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

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-003]],
[[SPEC-014-harness-evolution-control-plane#TEST-024]].

### REQ-004 — Fail-closed invariant checks

An installed invariant filter SHALL veto when its reasoner query fails or
returns malformed evidence. The self-modification port SHALL follow the same
rule.

A valid proof result is a finite proper property list containing exactly one
each of `:tag`, `:derivation`, and `:time-ms`. The tag SHALL be one of the four
documented positive or negative proof tags. Derivation SHALL be a proper list
or `nil`, and time SHALL be a nonnegative integer. Every other shape is
malformed and SHALL deny the guarded action.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-004]],
[[SPEC-014-harness-evolution-control-plane#TEST-025]].

### REQ-005 — Optional subsystem

Evolution APIs SHALL load only through `imago/evolution`. Loading `imago` SHALL
NOT create an evolution store or register evolution tools. Candidate processes
SHALL NOT receive the control-plane system, store authority, or store path.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-005]].

### REQ-006 — Explicit responsibility records

Every actor SHALL use a `did:key` identity. Candidate, evaluation, and
promotion records SHALL carry signatures from their responsible actors.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-006]].

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

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-010]],
[[SPEC-014-harness-evolution-control-plane#TEST-027]].

### REQ-011 — Evaluation role separation

A held-out evaluation SHALL use distinct creator, executor, and evaluator
identities. Executors and evaluators SHALL belong to configured disjoint trust
rosters. A promotion decision SHALL require their valid signatures.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-011]].

### REQ-012 — Correctness before capability

Eligibility SHALL retain every held-out task the baseline completes correctly.
It SHALL NOT replace task correctness with diagnostic quality.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-012]].

### REQ-013 — Repetition and cross-executor evidence

Eligibility SHALL require a configurable minimum held-out repetition count.
Eligibility SHALL require a configurable minimum executor count. Repetition
and executor minima SHALL each be at least two.

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

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-016]],
[[SPEC-014-harness-evolution-control-plane#TEST-029]].

### REQ-017 — No in-place candidate mutation

Verification SHALL recompute the candidate image digest. A changed image SHALL
invalidate evaluation and promotion operations.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-017]].

### REQ-018 — Baseline-relative decision report

A decision SHALL compare candidate and baseline held-out capability means. It
SHALL report capability delta, runtime cost, and candidate development cost.
It SHALL bind to the current ledger head and every unique held-out run.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-018]].

## Non-functional requirements

### NFR-001 — Determinism

Identical candidate bytes and manifest inputs SHALL produce the same candidate
identifier. Decision calculations SHALL be independent of ledger order.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-019]],
[[SPEC-014-harness-evolution-control-plane#TEST-031]].

### NFR-002 — Bounded core impact

The default `imago` system SHALL gain no evolution runtime dependency. Core
changes SHALL remain limited to repaired execution seams and exported contracts.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-005]].

### NFR-003 — Actionable decisions

An ineligible decision SHALL list every missing or failed gate. It SHALL not
return only a Boolean value.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-020]].

### NFR-004 — Safe recognition

Manifest, ledger, and pointer readers SHALL disable reader evaluation. They
SHALL validate a complete form before causing effects.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-021]],
[[SPEC-014-harness-evolution-control-plane#TEST-030]].

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
  :development-cost-microusd nonnegative-integer
  :wall-time-ms nonnegative-integer
  :input-tokens nonnegative-integer
  :output-tokens nonnegative-integer)
sha256 = 64 lowercase hexadecimal characters
ed25519-hex = 128 lowercase hexadecimal characters
```

The reader SHALL recognize the whole grammar before returning data.
The creator signature covers every manifest field except itself.

### CON-002 — Evidence event grammar

Each ledger line is exactly one property list. Every event carries `:event`,
`:timestamp`, `:candidate-id`, `:seq`, `:previous-hash`, and `:event-hash`.
Evaluation events also carry:

```text
:run-id :split :task-id :executor-did :evaluator-did :task-correct-p
:capability-score-micros :activation-evidence :duration-ms
:input-tokens :output-tokens :estimated-cost-microusd
:evaluator-signature :executor-signature
```

The accepted splits are `:development`, `:selection`, and `:held-out`.
Incomplete final lines are ignored. Malformed complete lines are rejected.
The event hash covers canonical event content and the prior event hash.
Actor signatures cover canonical event content without signature or chain fields.
Run identifiers SHALL be unique across the ledger.

The store maintains a separate signed head containing the terminal sequence and
event hash. Every read SHALL compare the chain against that head. The store
authority signs each head without its signature field using Ed25519.

### CON-003 — Tool authorization

When `*current-agent*` is bound, authorization is the conjunction below:

```text
registered(tool) AND member(tool, agent.tools)
```

Direct operator calls remain available only when `*current-agent*` is unbound.
Nested tool dispatch retains the current agent and the same restriction.

This contract governs the provider call path. It is not an isolation boundary
against arbitrary trusted Lisp running in the same process.

### CON-004 — Promotion gates

An eligible decision requires all conditions below:

```text
candidate digest valid
baseline digest valid
minimum held-out repetitions met
minimum distinct executors met
every baseline-correct task remains correct for the candidate
all selected runs contain activation evidence
all held-out evaluators differ from candidate creator
all held-out creator, executor, and evaluator identities are pairwise distinct
all held-out evaluator signatures verify against a configured trusted DID
candidate mean capability exceeds baseline mean by configured delta
trusted authorizer signature verifies over the eligible decision
```

The decision report SHALL expose each condition independently.
The decision SHALL consume every valid held-out event present at calculation
time. Callers SHALL NOT provide a selectable event subset.

The decision records the evidence head and its own event hash. Its authorizer
signs the decision without its authorization signature. Promotion SHALL reject
the decision unless its event remains the current ledger head.

The default minimum is three repetitions and two executors. Implementations
SHALL reject either minimum below two.

### CON-005 — Filesystem confinement

Candidate identifiers and pointer names SHALL match `[a-z0-9][a-z0-9-]{0,62}`.
Manifest image paths SHALL be relative basenames. Operations SHALL reject path
traversal before opening or creating a file.

### CON-006 — Canonical signed bytes

Every signed payload is a closed-schema property list with keys in contract
order. Nested property lists also use their declared contract order.

The canonical value grammar contains only `nil`, `t`, keywords, integers,
strings, and proper lists. Floating-point and other symbol values are invalid.
Capability scores use integer millionths. Costs use integer micro-US dollars.
All counters and durations are nonnegative integers.

Changed components and activation evidence are sorted unique string lists.
Strings reject control characters. Identifiers and DIDs use their declared
ASCII grammars.

The encoder binds `*package*` to `KEYWORD`, `*print-base*` to 10,
`*print-radix*` to `nil`, and `*print-case*` to `:downcase`. It also binds
`*print-pretty*` and `*print-circle*` to `nil`. It binds `*print-escape*` and
`*print-readably*` to `t`. SBCL `prin1` emits the value, with no trailing
whitespace. UTF-8 encodes that exact text.

A valid actor DID starts with `did:key:z6Mk`. `parse-did-key` SHALL decode it to
exactly 32 Ed25519 public-key bytes. Signatures are lowercase hexadecimal for
exactly 64 signature bytes.

## Threat boundary

The evolution store runs in an external evaluator process under operator-owned
filesystem permissions. Frozen candidate processes receive only copied image
bytes and task inputs. They do not receive the store path or private identities.

The ledger detects accidental or unauthorized edits within that boundary. It
does not defend against an operator who replaces both the ledger and its signed
head with a previously valid snapshot.

## Observability

### OBS-001 — Candidate freeze event

The ledger records candidate, parent, image digest, manifest digest, and creator.

### OBS-002 — Evaluation event

The ledger records executor, evaluator, task split, correctness, capability,
activation, latency, token use, and cost.

### OBS-003 — Decision event

The ledger records thresholds, gate results, means, deltas, and eligibility.

### OBS-004 — Promotion event

The ledger records pointer, prior candidate, new candidate, and authorizer.

### OBS-005 — Runtime authorization failure

A forbidden tool call returns `:unauthorized` in the canonical tool result.

### OBS-006 — Reasoner failure

A reasoner error produces a vetoed result. The error does not authorize work.

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

Make the candidate regress on one baseline-correct task. Verify ineligibility
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
[[SPEC-014-harness-evolution-control-plane#CON-005]].
**Type:** prohibited action and scope invariant.

Attempt collision, traversal, and symlink targets. Verify prior candidate bytes,
the ledger prefix, and all paths outside the store remain unchanged.

### TEST-027 — Ledger chain integrity

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-010]].
**Type:** negative input and scope invariant.

Modify, delete, reorder, and truncate historical events. Verify chain validation
rejects each complete corruption and never changes the ledger or pointers.

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

Append a duplicate run identifier and verify rejection. Append evidence after a
decision, then verify the stale decision cannot change a pointer.

### TEST-035 — Disjoint role rosters

**Validates:** [[SPEC-014-harness-evolution-control-plane#REQ-011]].
**Type:** negative input.

Configure overlapping executor and evaluator rosters. Verify store creation
fails. Use disjoint rosters and verify only enrolled identities can attest.

## Traceability matrix

| Requirement | Verification | Control or observation |
|---|---|---|
| [[SPEC-014-harness-evolution-control-plane#REQ-001]] | [[SPEC-014-harness-evolution-control-plane#TEST-001]] | main-path activation |
| [[SPEC-014-harness-evolution-control-plane#REQ-002]] | [[SPEC-014-harness-evolution-control-plane#TEST-002]] | canonical provider frames |
| [[SPEC-014-harness-evolution-control-plane#REQ-003]] | [[SPEC-014-harness-evolution-control-plane#TEST-003]] | [[SPEC-014-harness-evolution-control-plane#CON-003]], [[SPEC-014-harness-evolution-control-plane#OBS-005]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-004]] | [[SPEC-014-harness-evolution-control-plane#TEST-004]] | [[SPEC-014-harness-evolution-control-plane#OBS-006]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-005]] | [[SPEC-014-harness-evolution-control-plane#TEST-005]] | [[SPEC-014-harness-evolution-control-plane#NFR-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-006]] | [[SPEC-014-harness-evolution-control-plane#TEST-006]] | [[SPEC-014-harness-evolution-control-plane#OBS-001]] through [[SPEC-014-harness-evolution-control-plane#OBS-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-007]] | [[SPEC-014-harness-evolution-control-plane#TEST-007]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-008]] | [[SPEC-014-harness-evolution-control-plane#TEST-008]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-009]] | [[SPEC-014-harness-evolution-control-plane#TEST-009]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-010]] | [[SPEC-014-harness-evolution-control-plane#TEST-010]] | [[SPEC-014-harness-evolution-control-plane#CON-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-011]] | [[SPEC-014-harness-evolution-control-plane#TEST-011]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-012]] | [[SPEC-014-harness-evolution-control-plane#TEST-012]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-013]] | [[SPEC-014-harness-evolution-control-plane#TEST-013]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-014]] | [[SPEC-014-harness-evolution-control-plane#TEST-014]] | [[SPEC-014-harness-evolution-control-plane#OBS-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-015]] | [[SPEC-014-harness-evolution-control-plane#TEST-015]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-016]] | [[SPEC-014-harness-evolution-control-plane#TEST-016]] | [[SPEC-014-harness-evolution-control-plane#OBS-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-017]] | [[SPEC-014-harness-evolution-control-plane#TEST-017]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-018]] | [[SPEC-014-harness-evolution-control-plane#TEST-018]] | [[SPEC-014-harness-evolution-control-plane#OBS-003]] |
| [[SPEC-014-harness-evolution-control-plane#NFR-001]] | [[SPEC-014-harness-evolution-control-plane#TEST-019]] | content addressing |
| [[SPEC-014-harness-evolution-control-plane#NFR-002]] | [[SPEC-014-harness-evolution-control-plane#TEST-005]] | optional subsystem boundary |
| [[SPEC-014-harness-evolution-control-plane#NFR-003]] | [[SPEC-014-harness-evolution-control-plane#TEST-020]] | decision gate map |
| [[SPEC-014-harness-evolution-control-plane#NFR-004]] | [[SPEC-014-harness-evolution-control-plane#TEST-021]] | [[SPEC-014-harness-evolution-control-plane#CON-001]], [[SPEC-014-harness-evolution-control-plane#CON-002]], [[SPEC-014-harness-evolution-control-plane#CON-005]] |

## Amendment channels

- New candidate fields require a versioned [[SPEC-014-harness-evolution-control-plane#CON-001]] amendment.
- New evidence events require a versioned [[SPEC-014-harness-evolution-control-plane#CON-002]] amendment.
- Promotion threshold changes remain runtime policy inputs.
- New automatic mutation or promotion behavior requires a new specification.

## Non-goals

- This version does not generate mutations.
- This version does not reveal held-out task content to creators.
- This version does not choose providers or models.
- This version does not claim autonomous recursive improvement.
- This version does not replace an external benchmark runner.

## Gate evidence record

| Gate | Required evidence | Status |
|---|---|---|
| Specification lint | `usdd-lint.sh --strict` reports zero errors and warnings | pass |
| Reference integrity | no SPEC-014 dead links or syntax errors | pass |
| Comprehension | [[SPEC-014-REVIEW#Comprehension gate]] | pass |
| Adversarial review | [[SPEC-014-REVIEW#Adversarial findings]] | pass after amendments |
| Red Gate | failing targeted tests before implementation | pending |
| Implementation | targeted and full test output | pending |
| Theory closure | Elephant task evidence and fingerprint | pending |

## References

- HarnessDev, arXiv:2609.01437, <https://arxiv.org/abs/2609.01437>.
- [[SPEC-012-self-modification-port]].
- [[SPEC-013-skill-definition-port]].
