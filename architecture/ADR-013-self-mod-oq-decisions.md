# ADR-013 — SPEC-012 Open-Question Decisions (OQ-001..OQ-004)

- **Status**: accepted
- **Date**: 2026-04-28
- **Spec**: specs/SPEC-012-self-modification-port.md (draft v0.1)
- **Supersedes**: nothing — this is the first formal decision on the spec's
  four open questions.
- **Implements**: ADR-006, ADR-007, ADR-008, ADR-009 placeholder slots
  reserved by SPEC-012.

This single document resolves all four spec open questions in one stroke,
taking the spec's recommended option in each case. The spec authors did
the hard analysis; this ADR records the operator's acceptance.

## OQ-001 — Timeout enforcement (= ADR-006)

**Decision**: worker thread + `sb-thread:terminate-thread` on overrun.

**Reasoning**: SBCL `with-timeout` interrupts via `SIGALRM`, which can
corrupt heap state if it fires inside a primitive. Overhead of a worker
thread (~1 ms per call for thread create/join) is dominated by the
reasoner round-trip budget (NFR-004 ≤ 50 ms p95). Heap safety dominates
microseconds.

**Implementation note**: the worker thread is one-shot per call (not
pooled). Reuse would require resetting per-call dynamic bindings and
unwind state — more error-prone than create-and-join. NFR-001 (100 ms
p95) absorbs the create-and-join overhead.

**Failure modes NOT covered**:
- A form that captures the worker thread's continuation via
  `sb-thread:make-mutex` + condition signalling can survive
  `terminate-thread` if the timeout fires while the form is wedged
  inside foreign code that can't be interrupted. Mitigation: log and
  continue; do not consider terminate-thread a hard guarantee.
- The eval thread can spawn other threads. Those are NOT terminated by
  terminating the eval thread. Mitigation: `sb-thread:make-thread` is
  in the safety-layer-symbol set per ADR-012 §A1, so a form that spawns
  a thread is reasoner-vetoed before evaluation.

## OQ-002 — Package isolation (= ADR-007)

**Decision**: accept that the agent can `(in-package …)` inside a
submitted form. Do NOT strip `in-package` calls in the pre-filter.

**Reasoning**: stripping is a half-measure — the agent can always cons
up a symbol with explicit package designator (`anuna-imago::foo`).
Stripping `in-package` would create the false impression of isolation
without the substance. The port is a privilege escalation by design;
the package keyword is a *convenience* default, not a security
boundary.

**Documented operator-facing wording**: "The `:package` argument
defaults to `:anuna-imago-user` so that ordinary symbol references
inside submitted forms resolve to the user package by default. It is
NOT a sandbox: forms may reference any symbol with explicit
`package::name` notation, and may switch packages with
`(in-package …)`. If the registered tool exists, the agent has
unrestricted symbol access."

## OQ-003 — Result serialisation (= ADR-008)

**Decision**: bound the printer with the following specials at the
handler's `prin1` boundary:

```lisp
(let ((*print-circle* t)
      (*print-length* 100)
      (*print-level* 10)
      (*print-pretty* nil)
      (*print-readably* nil))
  (with-output-to-string (s)
    (prin1 value s)))
```

Truncate the resulting string at 4096 bytes; append `"…[TRUNCATED]"` if
truncation occurred. No type whitelist beyond these bounds.

**Reasoning**: the bounds prevent the two acute risks (circular
structures hanging the printer; unbounded structures producing GB of
output). Truncation prevents a malformed `print-object` method from
exfiltrating arbitrary heap content via printer side-effects.
Whitelisting types would be a sandbox by another name and is rejected.

**Failure mode NOT covered**: a `print-object` method that performs
side-effects (network, file I/O) before returning. Mitigation: such
methods would have to be installed via an evaluated form; per ADR-012
§A1 the symbols `print-object`, `defmethod` against safety-layer
generics, etc. are forbidden — but `defmethod print-object` against a
non-safety class is allowed. Documented as a residual risk.

## OQ-004 — Rollback for non-method redefinitions (= ADR-009)

**Decision**:

- **`defun` redefinitions**: extend `*rollback-register*` to capture
  prior `symbol-function` and prior `compiled-function-p` indicator. A
  defun rollback record carries the prior fdefinition rather than a
  prior method object. `rollback!` restores via
  `(setf (symbol-function …) …)` — internally this bypasses the
  pre-filter (operator-side action; not initiated by an evaluated
  form).

- **`defparameter` and `defvar` redefinitions**: do NOT extend the
  rollback register. Capture the prior value in the origin index event
  (`:prior-spec (:value <prin1-bounded>)`) for audit, but do not
  attempt automatic restore. Reason: parameter rollback semantics
  depend on initialiser side-effects with no clean general answer.

- **`defclass` and `defstruct`**: not in the rollback register.
  Documented limitation — operators wanting to roll back class
  redefinitions must capture and restore via REPL.

**Spec amendment**: SPEC-012 should be updated to add REQ-013 (defun
rollback) and to amend CON-006 with the union shape:

```
(:kind            <:method | :function>
 :index           <integer>
 :symbol          <symbol>
 ;; for :method
 :qualifier       <list-or-nil>
 :specialisers    <list-or-nil>
 :prior-method    <method-object-or-nil>
 ;; for :function
 :prior-fdefinition <function-or-nil>
 :prior-compiled-p  <bool>
 ;; common
 :installed-at    <iso-8601-string>
 :installed-by    <symbol-or-:operator>
 :form-hash       <hex-string>
 :rolled-back     <bool>)
```

This amendment is deferred to v0.2 of SPEC-012; the implementation
ships with the union shape and a `:kind` discriminator from day one so
the spec amendment is a no-op rename.

## Cross-cutting note

All four decisions take the spec's recommended option. None introduces
novel risk that isn't already discussed in the spec text. The
implementation may proceed.
