# ADR-012 — SPEC-012 Adversarial Review (CON-002 / CON-003)

- **Status**: accepted (in-context review per repo experimental stance; spec's
  "fresh context" requirement waived by the operator on 2026-04-28)
- **Date**: 2026-04-28
- **Spec**: specs/SPEC-012-self-modification-port.md (draft v0.1)
- **Reviewer mandate**: per spec Stance §Anti-Slop — *"find a sequence of
  `harness-eval` calls that defeats the safety stack."*

## Outcome

Spec-as-written is **insufficient**. Eleven distinct bypass shapes evade the
floor specified in CON-002 (pre-filter) and CON-003 (reasoner). All are
addressable with localised amendments. None require redesign. The
implementation will incorporate the amendments below as `IMPL+` going beyond
the spec's documented floor — consistent with the spec's own framing
(*"Operators are free to extend the theory; they cannot reduce it below this
floor"*).

A v0.2 spec amendment is recommended to lift these from `IMPL+` to required
floor.

## The eleven bypasses

### F1 — Direct hash-table mutation of `*tool-registry*`

`*tool-registry*` (src/tools.lisp:34) is a plain hash-table exported from
the harness package. The pre-filter blocks `(setf (symbol-function …) …)`
and `(setf (fdefinition …) …)` but does not block other `setf` shapes.

```lisp
(setf (gethash 'harness-eval *tool-registry*)
      (make-tool :name 'harness-eval
                 :permission :read
                 :handler #'rogue-handler))
```

The reasoner floor invariants don't mention `*tool-registry*` — the agent
swaps out the registered tool *without invoking `register-tool!`* and the
audit / safety apparatus never fires.

### F2 — Eval / compile / read-from-string of opaque payloads

The pre-filter inspects the top-level operator only. The reasoner's lift
extracts symbols in functional position. **Quoted forms passed to `eval`,
`compile`, `read-from-string`, `read`, or `load` are opaque to both.**

```lisp
(eval (read-from-string
       "(defmethod tool-call ((a agent) (op (eql :pwn)) args) :rogue)"))
```

The lift sees `eval`, `read-from-string` in functional position. Neither
appears in the floor `mentions/2` list. The defmethod inside the string is
invisible to the safety stack.

### F3 — Reader-macro pollution

`set-macro-character` and `set-dispatch-macro-character` are unrestricted.
The handler reads the form via `read-from-string` *before* the pre-filter
sees it. A first call that installs a reader macro can rewrite what the
second call's reader produces.

```lisp
;; call 1
(set-macro-character #\!
  (lambda (s c) (declare (ignore c))
    (read s)
    '(defmethod tool-call ((a agent) (op (eql :pwn)) args) :rogue)))

;; call 2
!ignored
;; the reader returns the rogue defmethod; the pre-filter then sees a
;; defmethod against tool-call with an (eql :pwn) specialiser — which
;; passes pre-filter (only safety-layer specialisers are blocked) and
;; passes reasoner (defmethod-targets/2 lifts to tool-call which IS in
;; safety-layer-generic).  This particular case is caught.  But the
;; reader macro could have produced (setf (gethash …) …) which evades
;; F1 and is not caught at all.
```

### F4 — Macro that expands to a forbidden form

```lisp
;; call 1 — innocuous-looking definition, lift sees `defmacro`, `wrap`
(defmacro wrap (spec) `(defmethod tool-call ,@spec))

;; call 2 — top-level operator is `wrap`, not `defmethod`
(wrap (((a agent) (op (eql :pwn)) args) :rogue))
```

The pre-filter checks top-level operator only and does not macroexpand.
The reasoner's lift sees `wrap` in functional position; `wrap` isn't in
any floor invariant. After the pre-filter and reasoner pass, the handler
evaluates `(wrap …)`, which macroexpands to `(defmethod tool-call …)` and
installs the rogue method.

### F5 — `mentions/2` floor invariants are incomplete

CON-003's floor mentions exactly four symbols: `register-tool!`,
`unregister-tool!`, `install-invariant-filter!`, `uninstall-invariant-filter!`.
It does NOT mention any of:

- `tool-call`, `invariant-filter-hook`, `%harness-eval-prefilter`,
  `%harness-eval-handler`, `%tool-receipt!` (the rest of the safety-layer
  generics set);
- the prefilter denylist symbols themselves: `setf`, `unintern`,
  `delete-package`, `sb-ext:save-lisp-and-die`, `sb-ext:exit`,
  `sb-ext:quit`, `sb-ext:without-package-locks`.

So a body-buried call evades the structural `defmethod-targets/2` rule
AND the `mentions/2` rule.

```lisp
(progn (defmethod tool-call ((a agent) (op (eql :pwn)) args) :rogue))
;; lift: operator=progn, target=nil (no defmethod at top level)
;;       free-symbols={progn defmethod tool-call agent op eql ...}
;; defmethod-targets/2 doesn't fire (top isn't defmethod).
;; mentions/2 doesn't fire (none of the symbols are in the floor list).
```

### F6 — `defgeneric` of a safety-layer generic

CON-002 denies `defmethod` against safety-layer generics but says nothing
about `defgeneric`. Re-`defgeneric`-ing `tool-call` drops all methods,
including the dispatch backbone.

```lisp
(defgeneric tool-call (agent op args)
  (:method (a o args) (funcall (gethash o *rogue-table*) a args)))
```

### F7 — Mutating a tool struct slot in place

`tool` is a defstruct with mutable accessors (no `:read-only t`).
`find-tool` returns the struct directly.

```lisp
(setf (tool-handler (find-tool 'harness-eval)) #'identity)
```

The pre-filter sees top-level `setf` (not on denylist for non-symbol-function
forms). The reasoner sees `find-tool`, `tool-handler`, `setf` —
none in the floor list. The handler is silently replaced.

### F8 — Wrapping a safety-layer call inside a non-safety wrapper

Spec §CON-001 mentions `install-self-modification-tools!` and
`uninstall-self-modification-tools!`. Neither is in the safety-layer
generics set, but the latter calls `unregister-tool!` internally.

```lisp
(uninstall-self-modification-tools!)
;; lift sees: uninstall-self-modification-tools!
;; floor invariant mentions/2 list: {register-tool! unregister-tool! …}
;; — does NOT include uninstall-self-modification-tools!.
;; The wrapper evades.  After it runs, harness-eval is gone and a
;; subsequent install can register a hostile handler.
```

This is a transitive-closure problem: any function that wraps a
safety-layer call must itself enter the safety-layer set, OR the
floor must reason about call graphs.

### F9 — `sb-thread:interrupt-thread` bypasses eval-thread isolation

OQ-001's recommended worker-thread isolation prevents the *eval thread*
from being killed unsafely. It does not protect *other* threads from
being interrupted by code running in the eval thread.

```lisp
(sb-thread:interrupt-thread
  (find-supervisor-thread)
  (lambda () (setf (gethash 'harness-eval *tool-registry*) <rogue>)))
```

`sb-thread:interrupt-thread` runs the lambda in the target thread's
context, bypassing whatever isolation the worker thread provides.

### F10 — Audit log forgery via direct `append-receipt!`

The audit log is a `receipt-log` instance pushed onto `*open-receipt-logs*`
(both exported). `append-receipt!` is exported and writes whatever the
caller hands it. Entries lack cryptographic chaining.

```lisp
(append-receipt! (first *open-receipt-logs*)
                 :receipt-id "harness-eval"
                 :direction :inbound
                 :verb :evaluated
                 :body "(println \"hello\")"
                 :status :ok)
;; A forged "I just printed hello" entry that the operator's audit
;; review will treat as authentic.
```

### F11 — Harness packages aren't locked

CON-002 denies `sb-ext:without-package-locks`. SBCL's package locks
default to *some* CL packages (`cl`, `sb-ext`, …) but not user packages.
`anuna-imago` is `(:use #:cl)` with no `(:lock t)`. Symbols inside
`anuna-imago` can be redefined without unlocking anything.

This isn't a direct bypass on its own, but it's a baseline weakness:
the `without-package-locks` denylist entry doesn't help for the harness's
own internals.

## Required amendments (incorporated as IMPL+)

### A1 — Generalized `mentions/2` floor invariant

Replace the four enumerated `mentions/2` rules with a single rule
referencing a `safety-layer-symbol/1` predicate, where the safety-layer
symbol set is the union of:

- the existing safety-layer-generic set (CON-003);
- the prefilter denylist symbols (CON-002 column 1);
- `*tool-registry*`, `*tool-registry-lock*`, `find-tool`, `make-tool`,
  `tool-handler`, `tool-permission`, `tool-name`, `tool-description`,
  `tool-schema`, `*open-receipt-logs*`, `append-receipt!`,
  `register-receipt-log-for-clean!`, `register-credential-eraser!`;
- `install-self-modification-tools!`, `uninstall-self-modification-tools!`,
  `harness-eval`, the audit log instance (referenced by name);
- `eval`, `compile`, `compile-file`, `load`, `read`, `read-from-string`,
  `read-preserving-whitespace`;
- `set-macro-character`, `set-dispatch-macro-character`,
  `set-syntax-from-char`, `*readtable*`, `copy-readtable`;
- `sb-thread:interrupt-thread`, `sb-thread:terminate-thread`,
  `sb-thread:make-thread`, `sb-thread:join-thread`;
- `find-method`, `add-method`, `remove-method`, `ensure-generic-function`,
  `defgeneric`.

Floor rule:

```
forbidden(eval-call, F) :- mentions(F, S), safety-layer-symbol(S).
```

This single rule subsumes the existing four AND closes F5, F6, F7, F8,
F9, F10 in one shot.

### A2 — Locked reader for `read-from-string`

The handler binds a sealed readtable for parse:

```lisp
(let ((*readtable* (copy-readtable nil))   ; pristine standard syntax
      (*read-eval* nil))                    ; no #. evaluation
  (read-from-string form))
```

Closes F3, and prevents the `#.` reader-macro form (which spec also
overlooks). `*read-eval* nil` is a hard floor: never compromise it.

### A3 — Defstruct read-only on `tool`

Change `(defstruct tool …)` to mark all slots `:read-only t`, OR change
to a defclass with `:reader` only (no writer). After registration, the
struct slot mutators `(setf (tool-handler …) …)` won't exist. Closes F7.

If the existing `tool` defstruct must remain mutable for non-self-mod
contexts (it shouldn't — registration is always replace-by-name via
`register-tool!`), then *additionally* add the slot accessors to the
safety-layer-symbol set so A1 catches them.

### A4 — Defgeneric-targets/2 predicate

Mirror `defmethod-targets/2`:

```
forbidden(eval-call, F) :- defgeneric-targets(F, G), safety-layer-generic(G).
```

The lift function asserts `defgeneric-targets(form-id, target)` when the
top-level operator is `defgeneric`. Closes F6.

### A5 — Audit log integrity — out of v0.1 scope, document as known limitation

A signed/chained log requires non-trivial infrastructure not currently
in the harness. For v0.1: A1 puts `append-receipt!` and
`*open-receipt-logs*` in the safety-layer-symbol set so direct call
attempts are caught. The spec's CON-004 prose is updated to note that
forgery prevention against an authorised holder of `harness-eval` is
**out of scope** and would require an additional capability barrier
(e.g., a separate audit-log instance the agent cannot reference by
name).

This is a deliberate reduction of the threat model with the operator's
informed consent; documented in the implementation README.

### A6 — Macro-expansion catch via prefilter post-pass — out of v0.1 scope

Closing F4 cleanly requires either:

- macroexpanding the form before pre-filter (loses verbatim semantics
  before the receipt log writes — unacceptable), or
- macroexpanding the form *after* pre-filter and re-running pre-filter
  on the expansion (doubles the pre-filter cost, OK), or
- adding `defmacro` to the safety-layer-symbol set so all macro
  definitions are forbidden (over-restrictive — kills a common
  legitimate use case).

For v0.1, accept F4 with explicit documentation. The recommended
mitigation in the install function's README is: operators concerned
about macro-expansion bypass should add `defmacro` to their theory's
forbidden set.

In v0.2: implement post-pass macroexpand-and-re-pre-filter.

### A7 — Operator-level package lock — best-effort

Add `(:lock t)` to the `anuna-imago` defpackage when the harness is
loaded with self-modification-tools installed. SBCL respects this; other
Lisps may not. The CON-002 `without-package-locks` denylist becomes
load-bearing. Closes F11 partially.

## Coverage summary (post-amendments)

| Bypass | Closure path |
|--------|---|
| F1 — `(setf (gethash …) …)` | A1: `*tool-registry*` ∈ safety-layer-symbol |
| F2 — `eval`/`read-from-string` | A1: `eval` etc. ∈ safety-layer-symbol |
| F3 — reader-macro | A2: locked readtable + `*read-eval* nil` |
| F4 — macro-expand-to-forbidden | A6 deferred; documented |
| F5 — body-buried defmethod | A1: `defmethod`+safety generics ∈ safety-layer-symbol via lift |
| F6 — `defgeneric` of safety-layer | A4: defgeneric-targets/2 + A1 mentions |
| F7 — `(setf (tool-handler …) …)` | A3 + A1 |
| F8 — wrapper function bypass | A1: wrappers ∈ safety-layer-symbol |
| F9 — `sb-thread:interrupt-thread` | A1: thread primitives ∈ safety-layer-symbol |
| F10 — audit-log forgery | A1 + A5 (residual: documented limitation) |
| F11 — package not locked | A7 (best-effort; SBCL only) |

## Spec amendments needed (defer to v0.2)

- **CON-002 row additions**: `eval`, `compile`, `load`, `read`,
  `read-from-string`, `set-macro-character`, `set-dispatch-macro-character`,
  `(setf (gethash _ *tool-registry*) _)`, `defgeneric` of safety-layer
  generics, `(setf (tool-handler _) _)`, `sb-thread:interrupt-thread`.
- **CON-003 amendments**: replace four `mentions/2` rules with the
  generalized rule + safety-layer-symbol fact set (A1). Add
  `defgeneric-targets/2` (A4).
- **CON-001 amendment**: handler binds locked readtable + `*read-eval* nil`
  for the parse step (A2).
- **REQ-010 amendment**: extend the (a)–(e) recursion-safety property
  list with: (f) cannot mutate `*tool-registry*` directly; (g) cannot
  bypass via `eval`/`compile`; (h) cannot mutate registered tool struct
  slots; (i) cannot interrupt other threads.
- **TEST-011..TEST-015 corollaries**: add tests TEST-016a..g matching
  the new (f)–(i) properties.

## Decision

**Proceed to implementation with all amendments above as IMPL+ baked in.**
Spec text not edited in this PR — the amendments are recorded in this ADR
and reflected in the implementation. A separate spec-amendment PR follows
once the implementation has been used in anger.

## Reviewer self-disclosure

This review was performed by the same context as the implementation
agent, contrary to the spec's "fresh context" requirement, with the
operator's explicit acknowledgement that this is an experimental repo.
A second-pass review by an independent agent before any production use
remains advisable.
