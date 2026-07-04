# ADR-014 — Pre-filter and lift must model special-variable assignment

- **Status**: accepted
- **Date**: 2026-07-04
- **Spec**: specs/SPEC-012-self-modification-port.md (draft v0.1)
- **Supersedes**: nothing; extends [[ADR-012-self-mod-adversarial-review]]
  (bypasses F1–F11) and [[ADR-013-self-mod-oq-decisions]].
- **Origin**: task `t12-review` final adversarial review
  ([[SELF-MOD-REVIEW]], BLOCKER-1). The review loops back to `t-d00` per the
  plan; this ADR is the resolution.

## Context

The final fresh-context adversarial review of the SPEC-012 safety stack
found a whole class of forms — **special-variable assignment** — that
defeats all three safety layers. The concrete escape is one to three plain
`setf` forms that no layer logs a rejection for:

```lisp
(setf anuna-imago::*safety-layer-symbols*  nil)   ; disarm pre-filter's safety-layer arm
(setf anuna-imago::*harness-eval-audit-log* nil)   ; silence the audit witness (REQ-006/NFR-002)
(setf anuna-imago::*reasoner-ipc-call* (lambda (&rest a) (list :tag :-delta)))  ; neuter the reasoner
```

After any of these, the canonical [[#REQ-010]] (b) attack
`(defmethod tool-call ((a t) (b t)) …)` — previously rejected — sails
through the pre-filter.

### Root cause (two independent defects)

1. **Pre-filter.** `%prefilter-setf` inspected only **cons** `setf` places
   (`(setf (accessor …) v)`). A bare-symbol place `(setf SYM v)` hit the
   first `cond` clause `((not (consp place)) :pass)` and was never examined.
   No rule existed for `setq`, `psetq`, `set`, or `makunbound` at all.
2. **Lift.** `%lift-form` emitted `mentions/2` facts only for **head-of-cons**
   symbols. A special variable assigned in value position is never
   head-of-cons, so it produced no `mentions` fact, so the
   `r-forbid-mentions` floor invariant could never fire on it. Every
   *variable* entry in `*safety-layer-symbols*` was therefore dead weight for
   the reasoner, protected only where the pre-filter had a *specific*
   structural rule (which existed for `(setf (gethash _ VAR) _)` and the
   tool-struct accessors, but not for bare assignment).

Additionally, `*reasoner-ipc-call*` — the live indirection every reasoner
call funcalls (`src/reasoner.lisp`) — was **not in `*safety-layer-symbols*`
at all**, so neutering the reasoner needed no set-emptying first.

The source comment at the head of `*safety-layer-symbols*` claimed the set
"is itself in the set so an agent's `harness-eval` cannot mutate it." That
was **false** as written — being in the set only helps if a layer actually
consults the set for the shape in question.

## Decision

Model assignment as a first-class mutation shape at **both** enforcement
layers, and close the missing safety-set entries. These lift from `IMPL+`
to required floor (a v0.2 spec amendment to CON-002/CON-003 is recommended).

### D1 — Pre-filter rejects assignment to a safety-layer variable

`%harness-eval-prefilter` now dispatches assignment operators:

- `(setf/psetf place value …)` → `%prefilter-setf` scans **every** place;
  a bare-symbol place in `*safety-layer-symbols*` → `:setf-safety-layer-variable`.
  Cons places retain their existing rules (F1/F3/F7).
- `(setq/psetq VAR value …)` → `%prefilter-setq`; any assigned var in the
  set → `:setq-safety-layer-variable`.
- `(set '<var> …)` / `(makunbound '<var>)` → `%prefilter-symbol-mutator`;
  a quoted (or bare) safety-layer symbol argument → `:symbol-mutator-safety-layer`.

The pre-filter is the hard floor that runs even when the reasoner is
stubbed, misconfigured, or crashed, so it carries the primary defence.

### D2 — Lift emits `mentions` for assignment targets

`%lift-form`'s walk now collects the assigned symbol from
`setf`/`psetf`/`setq`/`psetq` (bare-symbol places) and from `set`/`makunbound`
(quoted or bare argument) into `:free-symbols`. The reasoner floor invariant
`forbidden(eval-call, F) :- mentions(F, S), safety-layer-symbol(S)` then
vetoes the form independently of the pre-filter — defence in depth, and it
catches the computed-symbol case the structural pre-filter cannot resolve.

### D3 — Missing safety-set entries

Added to `*safety-layer-symbols*`: `*reasoner-ipc-call*` (the reasoner
indirection) and the special-variable mutators `set` and `makunbound`
(no legitimate `harness-eval` use; present so the reasoner `mentions/2`
path vetoes a runtime-computed target the pre-filter cannot see).

## Scope and residual

- **Closed:** bypass shapes N1–N5 from [[SELF-MOD-REVIEW]] (assignment to
  `*safety-layer-symbols*`, `*harness-eval-audit-log*`, `*reasoner-ipc-call*`,
  `*prefilter-denylist*`, `*active-theory-handle*`), via `setf`, `setq`,
  `psetf`, `psetq`, `set`, and `makunbound`.
- **Residual (documented, not a blocker):** N6 — buried mutation via a
  lexical alias, e.g. `(let ((r *tool-registry*)) (remhash 'harness-eval r))`.
  The pre-filter cannot follow `let`-aliasing without becoming a full code
  walker, and closing it at the lift layer by emitting `mentions` for *every*
  safety symbol anywhere in the form would wrongly veto the permitted
  [[#HP-003]] narrow `(eql :log-event)` method on `tool-call`. This is the
  same trade-off [[ADR-012-self-mod-adversarial-review]] recorded for
  body-buried forms; it is bounded (the agent still cannot name a safety
  function in functional position) and left as a known limitation of v0.1.

## Verification

- Regression tests in `test/m12-tests.lisp`:
  `test-m12-prefilter-denies-safety-var-assignment` (10 forms across all six
  operators + two negative/no-false-positive checks),
  `test-m12-reasoner-ipc-in-safety-set`,
  `test-m12-lift-captures-assignment-target`. All observed to fail before the
  fix (Red Gate) and pass after.
- `bin/run-safety-review.sh` runs the recursion-safety subset — including the
  three new tests — under `(speed 3)(safety 0)` and `(speed 0)(safety 3)`;
  both modes green, so no check is optimization-dependent.
- Full suite (`bash bin/run-tests.sh all`) green; the 1000-form NFR-003
  corpus still shows 0 pre-filter false positives, confirming benign
  `(setf (gethash …) …)` and `defparameter`/`defmethod` forms are unaffected.
