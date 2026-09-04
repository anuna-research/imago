---
id: SPEC-014
title: Harness Evolution Control Plane
status: approved
version: 0.2.0
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

**Load-bearing requirements:**

- [[SPEC-014-harness-evolution-control-plane#REQ-003]] enforces agent tool authority.
- [[SPEC-014-harness-evolution-control-plane#REQ-004]] makes invariant failures deny actions.
- [[SPEC-014-harness-evolution-control-plane#REQ-007]] freezes content-addressed candidates.
- [[SPEC-014-harness-evolution-control-plane#REQ-011]] separates evaluation roles.
- [[SPEC-014-harness-evolution-control-plane#REQ-020]] requires matched comparison cells.
- [[SPEC-014-harness-evolution-control-plane#REQ-024]] applies a conservative replicate gate.
- [[SPEC-014-harness-evolution-control-plane#REQ-032]] separates decision authority.

**Controls:**

- [[SPEC-014-harness-evolution-control-plane#CON-001]] defines candidate manifest grammar.
- [[SPEC-014-harness-evolution-control-plane#CON-002]] defines append-only evidence grammar.
- [[SPEC-014-harness-evolution-control-plane#CON-003]] defines authorization checks.
- [[SPEC-014-harness-evolution-control-plane#CON-004]] defines promotion gates.
- [[SPEC-014-harness-evolution-control-plane#CON-005]] defines filesystem confinement.
- [[SPEC-014-harness-evolution-control-plane#CON-006]] defines signed bytes.
- [[SPEC-014-harness-evolution-control-plane#CON-007]] defines matched comparison methodology.

**Open items:** None for version 0.2. Operational boundaries appear under Non-goals.

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

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-006]],
[[SPEC-014-harness-evolution-control-plane#TEST-036]].

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

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-016]],
[[SPEC-014-harness-evolution-control-plane#TEST-029]].

### REQ-017 — No in-place candidate mutation

Verification SHALL recompute the candidate image digest. A changed image SHALL
invalidate evaluation and promotion operations.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-017]].

### REQ-018 — Baseline-relative decision report

A decision SHALL compare candidate and baseline held-out capability means. It
SHALL report capability delta and candidate development cost separately.
It SHALL bind to the current ledger head and every unique held-out run.

Trace: [[SPEC-014-harness-evolution-control-plane#TEST-018]].

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
  :capability-score-micros nonnegative-integer
  :activation-evidence activation-evidence
  :duration-ms nonnegative-integer
  :input-tokens nonnegative-integer
  :output-tokens nonnegative-integer
  :estimated-cost-microusd nonnegative-integer
  :executor-signature ed25519-hex
  :evaluator-signature ed25519-hex
  :seq positive-integer
  :previous-hash sha256
  :event-hash sha256)
```

Campaign, benchmark, run, and task identifiers are nonempty ASCII strings.
The three configuration fields are SHA-256 values. A replicate index is a
positive integer. Run completion and task correctness are Boolean values.

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

Executor and evaluator signatures SHALL cover every evaluation field before
the signature and chain fields are added. A missing actor signature is malformed.

Ledger recognition SHALL reject a `(campaign-id, benchmark-id, task-id)` tuple
appearing in both split classes, regardless of candidate identifier.

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

Capability and efficiency gates are separate conjunction terms. A passing
capability result SHALL NOT offset an efficiency failure.

Store construction SHALL reject pairwise trust-roster overlap before creating
or changing store files.

The decision records the evidence head and its own event hash. Its authorizer
signs the decision without its authorization signature. Promotion SHALL reject
the decision unless its event remains the current ledger head.

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

The canonical value grammar contains only `nil`, `t`, keywords, integers,
strings, and proper lists. Floating-point and other symbol values are invalid.
Capability scores use integer millionths. Costs use integer micro-US dollars.
All counters and durations are nonnegative integers.

Manifest changed components and manifest activation evidence are sorted unique
string lists. Evaluation activation records follow [[SPEC-014-harness-evolution-control-plane#CON-002]].
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

Version 0.2 uses one writer per store. Multi-process writer coordination and
crash recovery remain external operational responsibilities.

These boundaries do not relax complete recognition, fail-closed ledger checks,
atomic pointer replacement, or [[SPEC-014-harness-evolution-control-plane#CON-005]].

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

## Traceability matrix

| Requirement | Verification | Control or observation |
|---|---|---|
| [[SPEC-014-harness-evolution-control-plane#REQ-001]] | [[SPEC-014-harness-evolution-control-plane#TEST-001]] | main-path activation |
| [[SPEC-014-harness-evolution-control-plane#REQ-002]] | [[SPEC-014-harness-evolution-control-plane#TEST-002]] | canonical provider frames |
| [[SPEC-014-harness-evolution-control-plane#REQ-003]] | [[SPEC-014-harness-evolution-control-plane#TEST-003]] | [[SPEC-014-harness-evolution-control-plane#CON-003]], [[SPEC-014-harness-evolution-control-plane#OBS-005]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-004]] | [[SPEC-014-harness-evolution-control-plane#TEST-004]] | [[SPEC-014-harness-evolution-control-plane#OBS-006]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-005]] | [[SPEC-014-harness-evolution-control-plane#TEST-005]] | [[SPEC-014-harness-evolution-control-plane#NFR-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-006]] | [[SPEC-014-harness-evolution-control-plane#TEST-006]], [[SPEC-014-harness-evolution-control-plane#TEST-036]] | [[SPEC-014-harness-evolution-control-plane#OBS-001]] through [[SPEC-014-harness-evolution-control-plane#OBS-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-007]] | [[SPEC-014-harness-evolution-control-plane#TEST-007]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-008]] | [[SPEC-014-harness-evolution-control-plane#TEST-008]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-009]] | [[SPEC-014-harness-evolution-control-plane#TEST-009]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-010]] | [[SPEC-014-harness-evolution-control-plane#TEST-010]] | [[SPEC-014-harness-evolution-control-plane#CON-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-011]] | [[SPEC-014-harness-evolution-control-plane#TEST-011]], [[SPEC-014-harness-evolution-control-plane#TEST-035]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-012]] | [[SPEC-014-harness-evolution-control-plane#TEST-012]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-013]] | [[SPEC-014-harness-evolution-control-plane#TEST-013]], [[SPEC-014-harness-evolution-control-plane#TEST-040]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-014]] | [[SPEC-014-harness-evolution-control-plane#TEST-014]], [[SPEC-014-harness-evolution-control-plane#TEST-042]] | [[SPEC-014-harness-evolution-control-plane#OBS-002]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-015]] | [[SPEC-014-harness-evolution-control-plane#TEST-015]] | [[SPEC-014-harness-evolution-control-plane#CON-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-016]] | [[SPEC-014-harness-evolution-control-plane#TEST-016]] | [[SPEC-014-harness-evolution-control-plane#OBS-004]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-017]] | [[SPEC-014-harness-evolution-control-plane#TEST-017]] | [[SPEC-014-harness-evolution-control-plane#CON-001]] |
| [[SPEC-014-harness-evolution-control-plane#REQ-018]] | [[SPEC-014-harness-evolution-control-plane#TEST-018]] | [[SPEC-014-harness-evolution-control-plane#OBS-003]] |
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
| [[SPEC-014-harness-evolution-control-plane#NFR-001]] | [[SPEC-014-harness-evolution-control-plane#TEST-019]], [[SPEC-014-harness-evolution-control-plane#TEST-031]], [[SPEC-014-harness-evolution-control-plane#TEST-045]] | content addressing and ordered reports |
| [[SPEC-014-harness-evolution-control-plane#NFR-002]] | [[SPEC-014-harness-evolution-control-plane#TEST-005]] | optional subsystem boundary |
| [[SPEC-014-harness-evolution-control-plane#NFR-003]] | [[SPEC-014-harness-evolution-control-plane#TEST-020]] | decision gate map |
| [[SPEC-014-harness-evolution-control-plane#NFR-004]] | [[SPEC-014-harness-evolution-control-plane#TEST-021]] | [[SPEC-014-harness-evolution-control-plane#CON-001]], [[SPEC-014-harness-evolution-control-plane#CON-002]], [[SPEC-014-harness-evolution-control-plane#CON-005]] |

## Amendment channels

- New candidate fields require a versioned [[SPEC-014-harness-evolution-control-plane#CON-001]] amendment.
- New evidence events require a versioned [[SPEC-014-harness-evolution-control-plane#CON-002]] amendment.
- Comparison semantics require a versioned [[SPEC-014-harness-evolution-control-plane#CON-007]] amendment.
- Promotion threshold values remain validated runtime policy inputs.
- New automatic mutation or promotion behavior requires a new specification.
- Runtime policy SHALL NOT waive roster separation, signed evidence, complete
  matching, fail-closed recognition, or filesystem confinement.

## Non-goals

- This version does not generate mutations.
- This version does not reveal held-out task content to creators.
- This version does not choose providers or models.
- This version does not claim autonomous recursive improvement.
- This version does not replace an external benchmark runner.
- This version does not verify evaluation-plan quality or task confidentiality.
- This version does not prove signer processes hold separate key custody.
- This version does not coordinate multiple store writers.
- This version does not provide interrupted-write recovery beyond atomic pointers.

## Gate evidence record

| Gate | Required evidence | Status |
|---|---|---|
| Specification lint | `usdd-lint.sh --strict` reports zero errors and warnings | pass |
| Reference integrity | no SPEC-014 dead links or syntax errors | pass |
| Comprehension | fresh-context version 0.2 review | pending |
| Adversarial review | independent version 0.2 review | pending |
| Red Gate | failing targeted tests before implementation | pending |
| Implementation | targeted and full test output | pending |
| Theory closure | Elephant task evidence and fingerprint | pending |

## References

- HarnessDev, arXiv:2609.01437, <https://arxiv.org/abs/2609.01437>.
- [[SPEC-012-self-modification-port]].
- [[SPEC-013-skill-definition-port]].

## Changelog

<details>
<summary>Revision history — 0.1.0 to 0.2.0</summary>

- 0.2.0 — Adds matched protocol replicates, transfer gates, activation binding,
  efficiency limits, campaign isolation, and independent authorization.
- 0.1.1 — Defines exact fail-closed proof-result grammar.
- 0.1.0 — Establishes the signed evolution control plane.

</details>
