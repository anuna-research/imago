# SPEC-014 independent review

## Review identity

- Target: [[SPEC-014-harness-evolution-control-plane]].
- Reviewer: fresh-context subagent `spec014_adversarial/trace_audit`.
- Producer: root implementation session.
- Date: 2026-09-04.
- Method: comprehension, traceability, security, and prohibited-action review.

## Comprehension gate

The reviewer restated the design as a controlled promotion pipeline.
A creator mutates a disposable process, then freezes a content-addressed image.
Distinct executors and evaluators test frozen bytes on held-out tasks.
The control plane records signed evidence before an operator promotes a pointer.

The reviewer correctly distinguished capability from task correctness.
The reviewer also identified that rejected authorization leaves pointers unchanged.

Result: pass.

## Adversarial findings

### Finding 1 — Dispatch scope overclaim

The first draft treated an unbound `*current-agent*` as operator authentication.
The approved contract now limits the allowlist claim to provider dispatch.
The threat boundary excludes arbitrary trusted Lisp inside one process.

### Finding 2 — Unauthenticated promotion callback

The first draft accepted any authorizer callback.
The approved contract requires a configured trusted `did:key` signer.
The external evaluator process retains that private identity.

### Finding 3 — Distinct labels did not prove role separation

The first draft compared actor labels only.
The approved contract requires pairwise-distinct DIDs and disjoint trust rosters.
Executor and evaluator attestations are both signed.

### Finding 4 — Replay and stale decisions

The first draft permitted duplicate run identifiers and selectable evidence.
The approved contract consumes all held-out events and rejects duplicate runs.
Every decision binds to a ledger head. Later evidence makes that decision stale.

### Finding 5 — Ledger suffix deletion

The first draft used only a hash chain.
The approved contract adds a separately signed terminal head.
The threat boundary explicitly excludes operator rollback attacks on both files.

### Finding 6 — Ambiguous signed bytes

The first amendment left nested values and numeric formats ambiguous.
The approved contract defines a restricted value grammar and exact printer bindings.
Scores and costs use fixed integer units.

### Finding 7 — Self-referential signatures

The second amendment included event signatures in their signed payload.
The approved contract excludes signature and chain fields from actor payloads.
Head and authorization signatures follow the same exclusion rule.

### Finding 8 — Red Gate authorization and evidence gaps

The first Red Gate called provider dispatch outside agent context.
The corrected tests bind the actual agent path and exercise nested dispatch.
They also recognize the complete proof-result grammar instead of tags alone.
Malformed evidence now denies work in both invariant-controlled paths.

Result: pass after amendments.

## Traceability findings

The first draft had no orphan requirement or test identifiers.
It lacked explicit `Validates:` fields and separated prohibited-action tests.

The approved contract adds test-local attribution to every test.
It adds independent scope, replay, stale-decision, signature, and roster tests.

## Repository baseline limitations

The controlled-language linter reports zero errors and zero warnings for SPEC-014.
The new page has no dead links or syntax errors.

The vault-wide check still reports unrelated pre-existing issues.
Those include SPEC-013 dead links and one SPL error in
`theories/self-modification-floor.spl`.
