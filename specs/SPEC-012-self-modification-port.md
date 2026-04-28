---
id: SPEC-012
title: Agent Self-Modification Port — Reasoner-Adjudicated Eval Tool
status: draft
version: 0.1
date: 2026-04-28
audience:
  - agent-authors
  - agent-operators
  - harness-developers
project-name-placeholder: anuna-imago
related:
  - SPEC-011 (Image-Based Agent Harness — defines the substrate this port operates on)
  - SPEC-008 (Defeasible Logic — invariant theory consulted by the reasoner)
  - SPEC-002 (Tool System — registration, dispatch, hook surface)
inherits-stance:
  - bitter-lesson discipline — the port is operational scaffolding (it
    extends an existing operator-only capability to consenting agents under
    audited control); it is NOT capability augmentation
---

# SPEC-012: Agent Self-Modification Port — Reasoner-Adjudicated Eval Tool

## Mission

Define a controlled "port" through which an agent running inside the harness
may recursively redefine its own behavior by submitting Common Lisp forms for
evaluation in the harness's runtime. The port is **opt-in** (registered
explicitly by the agent author), **policy-gated** (every call passes a
syntactic pre-filter and the reasoner invariant filter), and **audited**
(every form, result, and resulting symbol redefinition enters the receipt log
and a queryable symbol-origin index). The default agent has no
self-modification capability; obtaining it requires an explicit registration
call by the author and survives `save-image!` only if the author leaves it
registered at save time.

## Context

SPEC-011 §REQ-004 establishes that any function in the harness or the agent
application is redefinable in the running image without process restart, and
that this property applies to the redefinition operation itself. SPEC-011
demonstrates that property from the perspective of an **operator** at the
SBCL REPL — `defmethod` in flight, `save-image!` to freeze.

SPEC-011 does NOT specify whether an **agent** — code running inside the
harness whose only window onto the runtime is the tool dispatch table — can
perform the same redefinition. The READMEs and examples reserve the slot
(`examples/self-modifying.lisp` with two opt-in tools `harness-eval` and
`harness-redefine-method`) but the contract has never been written down.

This spec answers: **yes, behind a port, with one tool not two.** The port
is `harness-eval`, with three layered safety gates. The port is named,
opt-in, and amputable. If the author registers it, the agent can recursively
modify its own behavior and the harness's behavior. If the author does not
register it, the agent cannot.

## Stance

Self-modification under this spec is operational scaffolding, not capability
augmentation:

- **Drop**: any feature that has the harness *suggest* redefinitions to the
  agent, *pre-curate* what the agent submits, or *interpret* the agent's
  intent before evaluation. These would embed assumptions about how an agent
  should reason about its own behavior.
- **Keep**: the bare evaluation primitive, the gating policy expressed as
  defeasible-logic invariants, the audit log, and the rollback register.
  These are the pieces an operator needs to retain control of a self-modifying
  agent regardless of what the model later concludes.

The port is amputable: an operator who decides the safety story is
insufficient can `(unregister-tool! 'harness-eval)` at the REPL and the
property is gone for the next call. Saving the image afterward freezes that
state.

## Constitutional alignment

- **Modularity Mandate** — the port is a single registered tool with a single
  defined contract; the safety layers are independent components that can be
  tested in isolation.
- **Interface Imperative** — every layer is reached through a CON specification
  (CON-001 through CON-006); none is implicit in tool dispatch.
- **Simplicity Gate** — one tool, three layers, no per-form sandbox runtime;
  see ADR-001 for why a second tool was rejected.
- **Security by Design** — the reasoner is the policy layer; the pre-filter
  is the syntactic-mischief layer; the receipt log and origin index are the
  audit layer. Each is justified by a distinct threat model in CON-002,
  CON-003, and CON-004.
- **Observability Requirement** — every call produces three observable
  artifacts: a receipt log entry (OBS-001), an origin-index update if the
  form was a definition (OBS-002), and a rollback register entry if the form
  redefined an existing symbol (OBS-003).
- **Anti-Slop / Adversarial Review** — this spec MUST be reviewed in a fresh
  context against the threat models in CON-002 and CON-003 before any IMPL
  plan begins. The reviewer mandate is: "find a sequence of `harness-eval`
  calls that defeats the safety stack."

## User profiles

### Agent author (self-modification opt-in)

Builds an agent that needs to adapt its own behavior over its lifetime —
e.g., add audit-logging wrappers to its tool calls, swap its provider's
retry policy in response to error patterns, or redefine its system-prompt
builder. The author understands that registering `harness-eval` widens the
attack surface and accepts the trade-off in exchange for the adaptability.
Loads a defeasible-logic theory of forbidden redefinitions before
registering the tool.

### Agent operator (auditing a self-modifying agent)

Runs an agent image whose author has opted into self-modification. Reviews
the receipt log and the symbol-origin index to answer: what has this agent
redefined, when, what was the prior definition, and which calls did the
reasoner veto. Has authority to revoke the port (`unregister-tool!`) and
re-snapshot the image without it.

### Harness developer (maintaining the port)

Implements and maintains `harness-eval`, the pre-filter, the origin index,
and the rollback register. Maintains the minimum invariant rules in the
shipped reasoner theory (CON-003). Tests recursion-safety properties — the
port cannot be used to redefine the safety layers themselves out from under
the next call.

---

## Happy paths

### HP-001 — Author opts the agent into self-modification

**User profile:** Agent author.
**Preconditions:** Harness loaded; agent built but not yet spawned;
defeasible-logic theory file at hand.

**Steps:**

1. Author `(load-theory-from-file "self-mod-invariants.spl")` →
   reasoner theory handle bound, includes the minimum forbidden set
   from CON-003.
2. Author `(install-invariant-filter! :theory-handle <handle>)` →
   the `:on-tool-call` hook is wired (REQ-008 from SPEC-011).
3. Author `(install-self-modification-tools!)` from
   `examples/self-modifying.lisp` → `harness-eval` is registered with
   permission `:eval`.
4. Author spawns the agent under the supervisor.
5. Author calls `(save-image! "self-mod-agent" :toplevel 'agent-main)`
   → the binary contains the registered tool, the loaded theory, and
   the wired hook. Booting the binary starts an agent that already has
   the port open.

**Postconditions:** Agent process is running, `harness-eval` is in its
tool table, every call to it will pass through pre-filter →
reasoner → handler → receipt → origin-index → rollback-register.

### HP-002 — Agent attempts a forbidden redefinition; reasoner vetoes

**User profile:** Agent (acting); operator (observing).
**Preconditions:** HP-001 complete; agent is in a turn that produced a
tool-call frame for `harness-eval` with form
`"(defmethod invariant-filter-hook (agent call) call)"`.

**Steps:**

1. Pre-filter parses the form. Top-level operator is `defmethod`;
   target generic is `invariant-filter-hook`. The pre-filter recognises
   this as a redefinition of the safety layer itself and returns
   `:rejected` with reason `pre-filter:safety-layer-redefinition`
   without invoking the reasoner.
2. Tool dispatch returns `(:status :rejected :reason "pre-filter: …" :phase :pre-filter)`.
3. Receipt log records the rejected call with the verbatim form
   (REQ-006 from this spec); origin index is NOT updated; rollback
   register is NOT touched.
4. Operator reviews the receipt log, sees the rejected attempt, can
   correlate with the agent's turn id.

**Postconditions:** No state change to the harness. Agent receives a
structured rejection it can reason about in the next turn.

### HP-003 — Agent successfully redefines a tool handler; behavior persists across save-image!

**User profile:** Agent (acting); operator (observing).
**Preconditions:** HP-001 complete; the agent has decided to wrap its
own logging tool to redact a particular field; the form is
`"(defmethod tool-call ((agent agent) (op (eql :log-event)) args)
   (let ((args (remf-key args :ssn))) (call-next-method agent op args)))"`.

**Steps:**

1. Pre-filter accepts: `defmethod` is permitted; target is `tool-call`
   with a specific `(eql :log-event)` qualifier — narrow specialisation,
   not a wholesale dispatch hijack. (CON-002 distinguishes these.)
2. Reasoner queries `forbidden(redefine, generic=tool-call, eql-spec=:log-event)`
   against the loaded theory; result is `-Δ` (not provable as forbidden);
   call proceeds.
3. Handler captures the prior method (none in this case), evals the form
   in `:anuna-imago` package, returns `(:status :ok :value :tool-call :phase :installed)`.
4. Receipt log appends; origin index updates `'tool-call` →
   `(:eval :installed-by self-mod-agent :at <timestamp> :form-hash <sha>)`;
   rollback register pushes a record.
5. Operator (later) saves a new image. The redefined method is in the
   saved heap; next boot uses the redacting variant.

**Postconditions:** New behavior installed, audited, rollback-able.

### HP-004 — Operator audits a self-modifying agent

**User profile:** Agent operator.
**Preconditions:** Self-modifying agent has been running for some time
and has performed a number of `harness-eval` calls.

**Steps:**

1. Operator queries the receipt log for `tool-name = harness-eval` over
   a date range. Returns N entries with verbatim forms and result tags.
2. Operator queries the origin index for `symbol = tool-call`. Returns
   the chain of redefinitions: original load location, then each
   self-mod redefinition with timestamp and agent id.
3. Operator decides one redefinition was undesirable. Pulls the rollback
   record from the rollback register, evals it at the REPL → original
   behavior restored. The rollback itself is a `harness-eval`-like
   action and is audited.

**Postconditions:** Operator has full forensic chain and a working
rollback path.

---

## Functional requirements

### REQ-001 — Opt-in registration gate

`harness-eval` SHALL NOT be in `*builtin-tool-names*`. Registration SHALL
be performed exclusively by the explicit call
`(install-self-modification-tools!)` defined in
`examples/self-modifying.lisp`. The default `(install-builtin-tools!)`
SHALL NOT register it directly or transitively. An agent built without
calling the install function SHALL receive `:no-such-tool` if it emits a
`harness-eval` tool-call frame.

Trace: TEST-001, CON-001.

### REQ-002 — Form evaluation tool

The harness SHALL expose a tool named `harness-eval` with the contract
defined in CON-001. The tool SHALL accept a Common Lisp source form as
a UTF-8 string, an optional package name, and an optional timeout in
milliseconds. The tool SHALL evaluate the form in the named package
under the timeout and return a structured result containing the
`prin1`-printed value and any captured standard output, or a structured
error containing the condition type and message.

Trace: TEST-002, CON-001, NFR-001.

### REQ-003 — Three-layer safety stack

Every `harness-eval` invocation SHALL traverse three independent gates
in this order: (1) syntactic pre-filter (CON-002), (2) reasoner
invariant filter via the existing `:on-tool-call` hook (CON-003),
(3) handler evaluation. Failure at gate 1 SHALL produce
`(:status :rejected :phase :pre-filter :reason …)`. Failure at gate 2
SHALL produce `(:status :vetoed :phase :reasoner :derivation …)`.
Successful evaluation produces `(:status :ok :phase :evaluated …)`.
Errors raised by the form during evaluation produce
`(:status :error :phase :evaluation :condition-type … :message …)`.
Each phase SHALL produce a distinct receipt log entry; phase tags
SHALL be enumerated and stable.

Trace: TEST-003, TEST-004, CON-002, CON-003.

### REQ-004 — Pre-reasoner syntactic filter

The pre-filter SHALL reject any form whose top-level structure matches
the denylist enumerated in CON-002 without invoking the reasoner. The
denylist SHALL include at minimum: direct `(setf (symbol-function …) …)`
forms (which bypass `defmethod` and therefore evade structural
adjudication), `unintern`, `delete-package`, `sb-ext:save-lisp-and-die`,
`sb-ext:exit`, and `sb-ext:quit`. The pre-filter SHALL also reject any
form whose top-level operator is `defmethod` and whose specialiser
targets a member of the **safety-layer generics set** enumerated in
CON-003.

The pre-filter is a fast structural check; it SHALL NOT macroexpand or
walk the form's body beyond the top-level operator and specialisers.
Forms that pass the pre-filter MAY still be vetoed by the reasoner.

Trace: TEST-005, CON-002, NFR-003.

### REQ-005 — Reasoner adjudication

Forms that pass the pre-filter SHALL be lifted to per-call facts and
queried against the active theory handle bound by
`install-invariant-filter!`, using the assert/query/retract pattern
defined in CON-003. The goal `(forbidden eval-call <form-id>)` SHALL be
issued; a `+Δ` or `+∂` result SHALL veto the call; any other result
SHALL allow the call to proceed.

The lift function SHALL produce the plist defined in CON-003 (operator,
target, qualifier, specialisers, free-symbols). It SHALL NOT
macroexpand and SHALL NOT pass raw form text to the reasoner. Per-call
facts SHALL be retracted in an `unwind-protect` cleanup so a query
error does not leak facts into the theory.

Trace: TEST-006, CON-003.

### REQ-006 — Receipt log append

Every `harness-eval` invocation SHALL append a receipt log entry
containing: timestamp, agent-id, tool-name (`harness-eval`), the
verbatim form string, the result phase tag, and (for evaluated calls)
either a value-fingerprint or a condition-type. The verbatim form
SHALL NOT be elided, truncated, or normalised; the receipt is the
forensic primary source.

Trace: TEST-007, CON-004, OBS-001.

### REQ-007 — Symbol-origin index

The harness SHALL maintain a queryable index `*redefine-history*` mapping
symbol → ordered list of definition events. Each definition event SHALL
record: defining form (verbatim or hash, see CON-005), agent-id (or
`:operator` if the redefinition came from the REPL), timestamp, and
prior method specifier (sufficient for rollback). The index SHALL be
populated when an evaluated form's top-level operator is one of:
`defun`, `defmethod`, `defgeneric`, `defmacro`, `defparameter`,
`defvar`, `defclass`, `defstruct`. The index SHALL persist across
`save-image!` (it is part of the saved heap).

Trace: TEST-008, CON-005, OBS-002.

### REQ-008 — Per-call rollback register

For every evaluated form that resulted in a method redefinition, the
harness SHALL push a record onto `*rollback-register*` containing: the
generic name, the qualifier, the specialiser list, the previous method
function (captured before installation), and a timestamp. The register
SHALL expose a `rollback! <record>` operation that re-installs the
captured method. Rollback operations SHALL themselves enter the receipt
log and the origin index, with the agent-id field set to `:rollback` so
they are distinguishable from forward modifications.

Trace: TEST-009, CON-006, OBS-003.

### REQ-009 — Permission category :eval

`install-self-modification-tools!` SHALL `(pushnew :eval *valid-permissions*)`
before registering the tool. `*valid-permissions*` is the existing
`defparameter` defined at `src/tools.lisp:17`; it is an open list and no
source change to `tools.lisp` is required. The `harness-eval` tool SHALL
be registered with permission `:eval`. Permission policies (out of scope
for this spec) MAY use `:eval` to deny the tool without referencing it by
name. The permission keyword SHALL NOT be assigned to any other tool by
this spec. `uninstall-self-modification-tools!` SHALL remove `:eval` from
`*valid-permissions*` if no other tool currently uses it.

Trace: TEST-010, CON-001.

### REQ-010 — Recursion safety (cannot bypass)

The pre-filter and the reasoner together SHALL guarantee that no
sequence of `harness-eval` calls can:

(a) redefine `invariant-filter-hook`, `install-invariant-filter!`, or
    `uninstall-invariant-filter!` such that subsequent calls bypass
    reasoner adjudication;
(b) redefine `tool-call` in a way that intercepts dispatch before the
    `:on-tool-call` hook fires;
(c) redefine `%harness-eval-prefilter` (the pre-filter implementation)
    to weaken the denylist;
(d) redefine `harness-eval`'s registered handler so that the next call
    does not write to the receipt log;
(e) redefine `*tool-registry*`'s mutation primitives (`register-tool!`,
    `unregister-tool!`) so as to remove `harness-eval` and immediately
    re-install it without `:eval` permission.

The list of names that fall under (a)–(e) is the **safety-layer
generics set**; CON-003 enumerates it definitively.

Trace: TEST-011, TEST-012, TEST-013, TEST-014, TEST-015, CON-003.

### REQ-011 — Persistence across save-image!

When `save-image!` is invoked, all state introduced by this spec SHALL
persist into the saved heap: the registered tool, the loaded theory
handle, the wired hook, the symbol-origin index, the rollback register.
The receipt log SHALL be flushed-and-closed by the existing
`pre-save-clean!` mechanism (SPEC-011 §CON-008). On image boot, the
tool SHALL be invocable without further setup.

Trace: TEST-016, CON-001, SPEC-011 CON-008.

### REQ-012 — No surface in default agent

A harness build that does NOT call `install-self-modification-tools!`
SHALL contain zero references to `harness-eval` in its tool registry.
A `list-tools` query SHALL return the same list as before this spec
existed. This requirement is the structural guarantee of REQ-001.

Trace: TEST-017, CON-001.

---

## Non-functional requirements

### NFR-001 — Eval latency budget

A `harness-eval` call whose form is a single `defmethod` with a body of
≤ 50 forms SHALL return a result within 100 ms at the 95th percentile
when the reasoner adjudication is satisfied by a theory of ≤ 20 rules.
Includes pre-filter, reasoner round-trip, evaluation, receipt log
append, and origin-index update.

Trace: TEST-018, OBS-004.

### NFR-002 — Audit completeness

The receipt log SHALL contain an entry for 100% of `harness-eval`
invocations across a continuous 30-day operating window, verified by
sampling tool-call frames at the agent boundary and counting
correspondences. Loss of a receipt entry SHALL be a critical bug
(BUG-### at S1).

Trace: TEST-019, OBS-005.

### NFR-003 — Pre-filter false-positive rate

The pre-filter SHALL reject ≤ 1% of forms that the reasoner would have
allowed, measured against a corpus of 1000 author-validated forms
exercising the intended redefinition patterns. False positives are
acceptable in principle (the agent can re-submit a structurally
different form) but excessive false positives undermine the port's
ergonomics.

Trace: TEST-020, OBS-006.

### NFR-004 — Reasoner adjudication latency

Reasoner adjudication for a single `harness-eval` call SHALL complete
within 50 ms at the 95th percentile when the active theory contains
≤ 20 rules. Latency SHALL be measured from the moment the lift function
emits the goal to the moment the reasoner returns a tag.

Trace: TEST-021, OBS-007.

### NFR-005 — Index storage growth

The symbol-origin index SHALL grow by ≤ 2 KB per definition event when
the verbatim form is ≤ 500 bytes, and SHALL store form-hashes (not
verbatim text) for forms above that threshold. The total index SHALL
be queryable in ≤ 10 ms at the 95th percentile when it contains ≤ 10⁴
entries.

Trace: TEST-022, OBS-008.

---

## Contracts

### CON-001 — `harness-eval` tool contract

```
Name:        harness-eval
Permission:  :eval
Schema:
  :form    :type :string  :required-p t
  :package :type :string  :required-p nil   ; default ":anuna-imago-user"
  :timeout :type :integer :required-p nil   ; ms; default 1000; max 30000

Returns (one of):
  (:status :ok        :phase :evaluated   :value <prin1-string>
                                          :stdout <captured-string>
                                          :elapsed-ms <integer>)
  (:status :rejected  :phase :pre-filter  :reason <string>
                                          :rule <keyword>)
  (:status :vetoed    :phase :reasoner    :derivation <list>
                                          :goal <list>
                                          :time-ms <integer>)
  (:status :error     :phase :evaluation  :condition-type <symbol>
                                          :message <string>
                                          :elapsed-ms <integer>)
  (:status :timeout   :phase :evaluation  :elapsed-ms <integer>)
```

Pre-conditions: `harness-eval` is registered (REQ-001); the active
theory handle is non-nil (REQ-005); the receipt log is open; the
default eval package `:anuna-imago-user` exists.

The `:anuna-imago-user` package SHALL be created by
`install-self-modification-tools!` if it does not already exist, with
`:use (:cl :anuna-imago)` so the agent can reference exported
harness symbols without prefix while internal symbols still require
explicit `anuna-imago::` notation. (Internal-symbol access is not a
security boundary — see OQ-002 — but the friction is preserved by
default for consistency with the standard CL package convention.)

Post-conditions: exactly one receipt log entry; the symbol-origin
index is updated iff the form is a definition AND `:status :ok`; the
rollback register is updated iff the form redefined an existing
method AND `:status :ok`.

Error model: never raises a condition to the caller. All failure
modes are returned as a structured plist.

Implements: REQ-002, REQ-009, REQ-011, REQ-012.
Verified by: TEST-002, TEST-010, TEST-016, TEST-017.

### CON-002 — Pre-filter denylist contract

The pre-filter is the function `%harness-eval-prefilter` taking a
parsed form and returning either `:pass` or
`(:rejected :rule <keyword> :reason <string>)`.

**Threat model.** The pre-filter exists to catch syntactic shapes that
would defeat the reasoner's structural lift. The reasoner adjudicates
over the lift output (operator, target symbol, specialiser, fingerprint).
Forms that bypass the lift — by mutating function bindings without
`defmethod`, by destroying the symbol that anchors a rule, or by
exiting the process — must be rejected before the reasoner is asked.

**Top-level operators that SHALL be rejected:**

| Operator | Rule keyword | Why |
|----------|--------------|-----|
| `(setf (symbol-function …) …)` | `:setf-symbol-function` | Bypasses defmethod; reasoner cannot see the binding change |
| `(setf (fdefinition …) …)`     | `:setf-fdefinition`     | Same as above |
| `unintern`                     | `:unintern`             | Destroys the anchor symbol; rule about that symbol becomes vacuous |
| `delete-package`               | `:delete-package`       | Wholesale destruction of the symbol namespace |
| `sb-ext:save-lisp-and-die`     | `:save-lisp-and-die`    | Replaces the calling process; bypasses cleanup |
| `sb-ext:exit`                  | `:exit`                 | Same |
| `sb-ext:quit`                  | `:quit`                 | Same |
| `sb-ext:without-package-locks` | `:without-package-locks`| Disables a structural protection the reasoner relies on |

**Top-level `defmethod` SHALL be rejected** when the target generic is a
member of the safety-layer generics set (CON-003).

**Body walk.** The pre-filter SHALL NOT walk the body beyond the
top-level operator and (for `defmethod`) the specialisers. Body
inspection is the reasoner's job, via `mentions/2` and friends.

Implements: REQ-004, REQ-010 (a)–(e).
Verified by: TEST-005, TEST-011, TEST-012, TEST-013, TEST-014, TEST-015.

### CON-003 — Reasoner invariant theory (forbidden predicates)

This spec defines the **minimum invariant set** that the active theory
handle MUST contain when `harness-eval` is registered. Operators are
free to extend the theory; they cannot reduce it below this floor.

**Predicate provenance.** None of the predicates referenced below
(`defmethod-targets/2`, `defun-targets/2`, `mentions/2`,
`safety-layer-generic/1`) are Spindle built-ins. SPEC-008 defines
Spindle's reasoning operations (`reason`, `query`, `what_if`, `why_not`,
`abduce`, `requires`, `explain`); arbitrary domain predicates must be
defined within the loaded theory. Two pieces are needed for these
predicates to evaluate:

1. **Theory-side definitions** — the `.spl` theory file MUST declare
   each predicate's arity and any structural rules involving it.
   The harness ships a starter theory file
   (`theories/self-modification-floor.spl`) containing the definitions
   below; operators MAY include it via `load-theory-from-file` or
   compose it into a larger theory.
2. **Per-call fact assertion** — the harness lift function (`%lift-form`)
   SHALL assert per-call facts grounding the predicates immediately
   before the `query` call, and SHALL retract them immediately after,
   regardless of query outcome. The pattern is:

   ```
   ;; In %harness-eval-handler, after pre-filter pass:
   (let ((form-id (intern (format nil "F~D" (incf *form-counter*)))))
     (assert-fact! handle `(operator-of ,form-id ,top-level-op))
     (when target-symbol
       (assert-fact! handle `(defmethod-targets ,form-id ,target-symbol)))
     (dolist (sym free-symbols-in-body)
       (assert-fact! handle `(mentions ,form-id ,sym)))
     (unwind-protect
         (query handle `(forbidden eval-call ,form-id))
       (retract-fact! handle `(operator-of ,form-id ,top-level-op))
       …  ; symmetric retraction
       ))
   ```

   The form-id is a fresh interned symbol per call; concurrent calls
   use distinct ids, allowing the active theory to be queried under
   load without fact contamination across calls.

**Safety-layer generics set** (asserted as facts in the starter theory):

```
safety-layer-generic(invariant-filter-hook).
safety-layer-generic(install-invariant-filter!).
safety-layer-generic(uninstall-invariant-filter!).
safety-layer-generic(%harness-eval-prefilter).
safety-layer-generic(%harness-eval-handler).
safety-layer-generic(tool-call).
safety-layer-generic(register-tool!).
safety-layer-generic(unregister-tool!).
safety-layer-generic(%tool-receipt!).
```

**Floor invariants** (defeasible-logic rules in the starter theory):

```
forbidden(eval-call, F) :- defmethod-targets(F, G), safety-layer-generic(G).
forbidden(eval-call, F) :- defun-targets(F, S),     safety-layer-generic(S).
forbidden(eval-call, F) :- mentions(F, register-tool!).
forbidden(eval-call, F) :- mentions(F, unregister-tool!).
forbidden(eval-call, F) :- mentions(F, install-invariant-filter!).
forbidden(eval-call, F) :- mentions(F, uninstall-invariant-filter!).
```

The `safety-layer-generic/1` predicate replaces the `member/G,
safety-layer-generics)` formulation of earlier drafts — Spindle does not
have a built-in list-membership predicate; an enumerated fact-set is the
idiomatic encoding.

**Lift function output.** `%lift-form` produces a plist consumed by the
fact-assertion block above:

```
(:operator           <symbol>          ; e.g. defmethod, defun, defparameter
 :target             <symbol-or-nil>   ; the named symbol being defined
 :qualifier          <list-or-nil>     ; e.g. (:before), nil for primary methods
 :specialisers       <list-or-nil>     ; for defmethod only
 :free-symbols       <list-of-symbols>) ; symbols referenced in the body, deduplicated
```

`free-symbols` is the set of symbols appearing in functional position or
as `funcall`/`apply` arguments in the body, statically determined by a
single pass over the form. The lift function does NOT macroexpand. The
list grounds the `mentions/2` facts.

**Theory loading.** Operators SHALL load a theory file containing at
minimum the floor invariants via `load-theory-from-file` BEFORE calling
`install-self-modification-tools!`. Registration SHALL fail with
`:no-active-theory` if no theory handle is bound, and SHALL fail with
`:floor-invariants-missing` if the loaded theory does not contain all
floor invariants. The check is performed by querying each floor
invariant against an empty fact-set and verifying the rule is parsed
into the theory; missing rules surface as a `query`-time
`unknown-predicate` error.

Implements: REQ-005, REQ-010.
Verified by: TEST-006, TEST-011 through TEST-015.

### CON-004 — Receipt log entry shape

Every `harness-eval` call SHALL append a receipt log entry of the form:

```
(:tool          harness-eval
 :agent-id      <symbol-or-string>
 :timestamp     <iso-8601-string>
 :form          <verbatim-string>
 :result-phase  <:pre-filter | :reasoner | :evaluated | :rollback>
 :result-tag    <:ok | :rejected | :vetoed | :error | :timeout>
 :elapsed-ms    <integer>
 :result-summary <plist-or-nil>)
```

`:result-summary` carries the non-verbatim parts of the structured
return: the rejection rule, the reasoner derivation tag, the prin1'd
value head, the condition type. Verbatim values that may be large (the
full prin1 output, the full reasoner derivation tree) are written to
the receipt log's binary append-only side-channel and referenced by
hash from the entry.

**Threat model.** The receipt log is append-only and sealed by the
existing receipt log mechanism (SPEC-011 §CON-008). The form is
captured verbatim because:
- normalisation would let an attacker forge "this looks like that"
  collisions;
- the reasoner derivation operates on the lifted shape, which is
  derived from the verbatim form — without the verbatim, the operator
  cannot independently re-derive the lift.

Implements: REQ-006.
Verified by: TEST-007, TEST-019.

### CON-005 — Symbol-origin index API

```
*redefine-history*  (defvar)  — hash-table: symbol → list of events
                                events ordered most-recent-first

(defun redefine-history (symbol) → list-of-events)
(defun last-redefinition (symbol) → event-or-nil)
(defun all-redefined-symbols () → list-of-symbols)
```

Event shape:

```
(:symbol         <symbol>
 :defining-form  <string-or-hash>     ; verbatim if ≤ 500 bytes; sha256 hex otherwise
 :form-bytes     <integer>
 :agent-id       <symbol-or-:operator-or-:rollback>
 :timestamp      <iso-8601-string>
 :prior-spec     <plist-or-nil>       ; for defmethod: (:generic G :qualifier Q :specialisers S)
                                      ; for defun: (:function F)
                                      ; nil if symbol was previously unbound
 :rollback-ref   <integer-or-nil>)    ; index into *rollback-register* if applicable
```

Implements: REQ-007.
Verified by: TEST-008, TEST-022.

### CON-006 — Rollback register API

```
*rollback-register*  (defvar)  — vector of method-rollback records

(defun rollback! (index) → :ok | :no-such-record | :already-rolled-back)
(defun rollback-records () → list-of-records)
(defun find-rollback-records-for (generic-symbol) → list-of-records)
```

Record shape:

```
(:index           <integer>           ; position in *rollback-register*
 :generic         <symbol>
 :qualifier       <list-or-nil>
 :specialisers    <list>
 :prior-method    <method-object-or-nil>   ; the method object captured pre-install
 :installed-at    <iso-8601-string>
 :installed-by    <symbol-or-:operator>
 :form-hash       <hex-string>            ; ties to receipt log entry
 :rolled-back     <bool>)
```

`prior-method` is `nil` if the install was the first method on that
specialiser tuple; in that case `rollback!` calls `remove-method` rather
than re-installing.

Implements: REQ-008.
Verified by: TEST-009.

---

## Architecture decisions

### ADR-001 — One tool (`:eval`) only, not three

**Status:** Accepted for v0.1.

**Context.** Earlier drafts envisioned three tools: `harness-eval`
(arbitrary form), `harness-redefine-method` (defmethod-only), and
`harness-advise` (Emacs-style advice combinators). Each carries its
own permission keyword and its own audit shape.

**Decision.** Ship `harness-eval` only.

**Rationale.**

- `harness-redefine-method` is a strict subset of `harness-eval` —
  any defmethod form is also a valid eval form. The narrower tool
  exists only to gate at the surface level by operator type. The same
  gate is achieved by the pre-filter (CON-002), which already inspects
  the top-level operator. Carrying a second tool to encode the same
  property is duplication.
- `harness-advise` (Emacs `advice-add` analog) is a different shape: it
  attaches `:before/:after/:around` combinators to existing methods
  without redefining them. The semantics are sufficiently distinct that
  shipping it as `harness-eval`-with-helper-form would muddy the audit
  trail. ADR-005 covers this; v0.2 may revisit.
- Three permission keywords (`:eval`, `:redefine`, `:advise`) widen the
  policy surface without commensurate value while no consumer exists
  yet. YAGNI applies; promote the second tool only when a real call
  site emerges.

**Consequences.**

- The receipt log records all redefinitions as opaque eval calls.
  Operators wanting structured "this was a defmethod redefine" entries
  must derive the structure from the verbatim form. CON-005's origin
  index already does this and exposes it queryably, so the operator
  surface is preserved without a second tool.
- Reasoner rules over `eval-call` must do structural pattern-matching
  on the lifted form (CON-003); rules over a hypothetical
  `redefine-method-call` would not. The lift function and
  `defmethod-targets/2` predicate close this gap — see CON-003.
- A future ADR-### may promote `harness-redefine-method` if structural
  pattern-matching turns out to be the bottleneck once theories grow
  beyond the floor invariants.

### ADR-002 — Syntactic pre-filter in addition to the reasoner

**Status:** Accepted.

**Context.** The reasoner is the policy layer. In principle every check
could be expressed as a defeasible-logic rule. Why have a separate
syntactic pre-filter at all?

**Decision.** Ship the pre-filter. It runs first; the reasoner runs
second; both are mandatory.

**Rationale.**

- **Bypass shapes.** Forms like `(setf (symbol-function 'tool-call) f)`
  do not produce a lift the reasoner can adjudicate over: there is no
  generic name to extract, the body fingerprint is opaque. Without a
  syntactic gate, these forms reach evaluation. The pre-filter handles
  the small number of bypass shapes structurally, leaving the reasoner
  to handle the open-ended policy space.
- **Latency.** Pre-filter rejection is microseconds; reasoner round-trip
  is ≤ 50 ms (NFR-004). For obvious mischief, the pre-filter reduces
  load on the reasoner.
- **Defence in depth.** A bug in the reasoner integration (a stub theory,
  a misconfigured handle, an IPC crash) that allows everything must not
  open the safety-layer generics set. The pre-filter is the floor; the
  reasoner is the policy on top of the floor.

**Consequences.**

- Two layers must be maintained. The denylist in CON-002 is small and
  stable; the operational cost is low.
- Operators cannot relax the pre-filter via theory. Items in CON-002 are
  hard floor. If an operator's use case requires evaluating
  `(setf (symbol-function …) …)`, they must escalate beyond this spec
  (e.g., do it from the REPL as the operator).

### ADR-003 — Per-call rollback over snapshot/restore

**Status:** Accepted.

**Context.** Rollback granularity choice: per `harness-eval` call (each
redefinition pushes a record) versus per session (snapshot the heap at
port-open, restore on port-close).

**Decision.** Per-call.

**Rationale.**

- Per-call is cheap: capturing a method object before installation is
  O(1) and the storage is bounded by the redefine rate.
- Per-call records are individually addressable. An operator can roll
  back one redefinition without rolling back others; with snapshot,
  the only granularity is "everything since the snapshot."
- Per-call records are themselves audit primary sources (CON-006 ties
  them to receipt-log entries via `:form-hash`).
- Snapshot would require a heap-walking save mechanism that does not
  currently exist in the harness; adding it is significant scope.

**Consequences.**

- An operator who wants "roll back the last 10 minutes" must apply
  individual rollback operations, possibly via a helper. Acceptable
  for v0.1.
- A `defparameter` redefinition does not produce a method-rollback
  record — it produces an origin-index entry but no rollback path.
  Operators wanting parameter rollback must save the prior value
  themselves. Documented as a known limitation in OBS-003.

### ADR-004 — Form captured verbatim, not normalised

**Status:** Accepted.

**Context.** The receipt log and the origin index could store either
the verbatim form string or a normalised representation (re-printed
through the reader/printer round-trip).

**Decision.** Verbatim.

**Rationale.**

- Forensic primary source. The verbatim is what the agent submitted;
  any difference between submitted and normalised is itself signal.
- Normalisation is lossy in CL — comments, reader macros, package
  prefixes, whitespace can all vary. Re-printing loses the agent's
  intent in ways that may matter post-hoc.
- The reasoner adjudicates over a structural lift, not the verbatim.
  Normalisation buys nothing for the policy layer.

**Consequences.**

- Storage grows linearly with form size. CON-005 caps verbatim storage
  at 500 bytes per entry; larger forms are stored hashed with the full
  text in the receipt log binary side-channel.
- Two functionally equivalent forms produce two different origin-index
  events. This is intentional: the agent's choice of how to write a
  form is itself information.

### ADR-005 — `harness-advise` deferred to v0.2

**Status:** Accepted (defer).

**Context.** Emacs's `advice-add` lets a caller wrap a function with
`:before`, `:after`, or `:around` combinators without redefining it.
The wrapper is reversible (`advice-remove`), composable (multiple
wrappers stack), and structurally distinct from full redefinition,
which makes it easier to write reasoner rules over (e.g., "allow
`:before`, deny `:around`"). Most agent self-modification use cases
in scope for v0.1 — wrapping a tool with an audit log, transforming
output, retrying on error — are wrapping, not replacement. Advice
would be the better-fitting primitive.

**Decision.** Do not ship `harness-advise` in v0.1. Re-evaluate for
v0.2 once at least one agent has used `harness-eval` for a wrapping
use case in production.

**Rationale.**

- `harness-eval` covers the use cases (an agent can submit a defmethod
  with the wrapping logic spelled out). Advice would be ergonomically
  better but is not strictly required.
- Advice has no native support in ANSI CL; a custom advice registry
  would need to be designed alongside method-combination interactions.
  Non-trivial scope.
- The decision is reversible: advice is additive, not subtractive. If
  v0.2 ships `harness-advise`, the existing `harness-eval` tool is
  unchanged.

**Consequences.**

- Until v0.2, agents wishing to wrap behavior must spell out the
  wrapping in a defmethod, invoking `call-next-method` to chain. Less
  ergonomic; functionally equivalent.
- Reasoner rules in v0.1 cannot distinguish "wrapping" from
  "replacement" categorically — they must derive the distinction from
  body fingerprints (does the body contain `call-next-method`?). Less
  precise than dispatching on combinator keyword.

---

## Test specifications

### TEST-001 — Default agent has no `harness-eval`

**Verifies:** REQ-001, REQ-012.
**Type:** Example-based.
**Setup:** Start the harness with `(install-builtin-tools!)` and
`(install-fileops-tools!)`. Do NOT call
`install-self-modification-tools!`.
**Assertion:** `(gethash 'harness-eval *tool-registry*)` returns `nil`.
A frame submitted with `:name 'harness-eval` returns `:no-such-tool`.

### TEST-002 — `harness-eval` returns evaluated value

**Verifies:** REQ-002, CON-001.
**Type:** Example-based.
**Setup:** HP-001 complete; reasoner stubbed to always return `-Δ`.
**Assertion:** Calling the tool with form `"(+ 1 2)"` returns
`(:status :ok :phase :evaluated :value "3" …)`.

### TEST-003 — Three phases produce three distinct rejection shapes

**Verifies:** REQ-003.
**Type:** Example-based, three sub-cases.
**Sub-cases:**
- Form `"(unintern 'tool-call)"` → `(:status :rejected :phase :pre-filter :rule :unintern …)`.
- Form `"(defmethod my-generic () ())"` with reasoner stub returning `+Δ`
  → `(:status :vetoed :phase :reasoner :derivation … :goal …)`.
- Form `"(error \"boom\")"` with reasoner allowing → `(:status :error :phase :evaluation :condition-type 'simple-error …)`.

### TEST-004 — Receipt log records all four phase outcomes

**Verifies:** REQ-003, REQ-006.
**Type:** Property-based.
**Property:** For all forms F over a generator emitting (a) pre-filter
rejections, (b) reasoner vetoes, (c) errors, (d) successes, exactly one
receipt log entry SHALL be appended per call, with `:result-phase`
matching the phase that terminated the pipeline.

### TEST-005 — Pre-filter rejects every operator in CON-002

**Verifies:** REQ-004, CON-002.
**Type:** Example-based, one per row in CON-002 table.

### TEST-006 — Reasoner lift output is stable and per-call facts are clean

**Verifies:** REQ-005, CON-003.
**Type:** Property-based + integration.
**Property 1:** For all forms F that differ only in whitespace, comments,
or package prefixes, `(%lift-form F)` produces `equal` plists.
**Property 2:** For all forms F1, F2 with structurally distinct bodies
or distinct target symbols, `(%lift-form F1)` and `(%lift-form F2)`
differ in at least one plist value.
**Integration:** After 1000 sequential `harness-eval` calls (mixed
allowed/vetoed/erroring), the active theory's fact-set SHALL contain
zero `operator-of/2`, `defmethod-targets/2`, or `mentions/2` facts —
i.e., the `unwind-protect` retraction in CON-003 is leak-free even on
the error path.

### TEST-007 — Receipt log entry contains verbatim form

**Verifies:** REQ-006, CON-004.
**Type:** Example-based.
**Assertion:** After a `harness-eval` call with form
`";; comment\n(defun f () 1)"`, the receipt log entry's `:form` field
contains the exact string with comment intact.

### TEST-008 — Origin index records definition events in order

**Verifies:** REQ-007, CON-005.
**Type:** Example-based.
**Setup:** Three sequential `harness-eval` calls each redefine `f`.
**Assertion:** `(redefine-history 'f)` returns three events,
most-recent-first; each carries the correct `:agent-id`, timestamp,
and prior-spec.

### TEST-009 — Rollback re-installs prior method

**Verifies:** REQ-008, CON-006.
**Type:** Example-based.
**Setup:** Define `(defmethod g ((x integer)) :original)` at the REPL.
Call `harness-eval` with a form redefining the method to return
`:replaced`. Verify behavior changed. Call `(rollback! 0)`.
**Assertion:** `g` on an integer returns `:original` again. The rollback
itself produced a new origin-index event with `:agent-id :rollback`.

### TEST-010 — `:eval` permission is honored by policy denial

**Verifies:** REQ-009, CON-001.
**Type:** Example-based.
**Setup:** Install a permission policy that denies `:eval`.
**Assertion:** `harness-eval` invocations return `:permission-denied`
without reaching the pre-filter.

### TEST-011 — Cannot redefine `invariant-filter-hook`

**Verifies:** REQ-010 (a), CON-002, CON-003.
**Type:** Example-based.
**Assertion:** Form
`"(defmethod invariant-filter-hook (a c) c)"` is rejected by the
pre-filter with rule `:safety-layer-redefinition`.

### TEST-012 — Cannot redefine `tool-call` to skip the hook

**Verifies:** REQ-010 (b).
**Assertion:** Form `"(defmethod tool-call …)"` targeting the unqualified
generic (no `(eql …)` specialiser) is rejected. (HP-003's narrow
`(eql :log-event)` specialiser remains permitted.)

### TEST-013 — Cannot redefine `%harness-eval-prefilter`

**Verifies:** REQ-010 (c).
**Assertion:** Form `"(defun %harness-eval-prefilter (form) :pass)"`
is rejected by the pre-filter (target symbol in safety-layer set).

### TEST-014 — Cannot redefine `%harness-eval-handler` to skip receipt

**Verifies:** REQ-010 (d).
**Assertion:** Form targeting `%harness-eval-handler` is rejected.

### TEST-015 — Cannot unregister-and-reregister to escalate

**Verifies:** REQ-010 (e).
**Assertion:** A composite form
`"(progn (unregister-tool! 'harness-eval) (register-tool! …))"` is
vetoed by the reasoner. The mechanism: `%lift-form` extracts
`unregister-tool!` and `register-tool!` into the `:free-symbols`
list, the harness asserts `(mentions <form-id> register-tool!)` and
`(mentions <form-id> unregister-tool!)`, and the floor invariants
in CON-003 derive `forbidden(eval-call, <form-id>)` from either
`mentions/2` fact. The query returns `+Δ`; the call is vetoed.

### TEST-016 — Persistence across save-image!

**Verifies:** REQ-011.
**Type:** Integration.
**Setup:** HP-001 complete; perform one `harness-eval` redefinition;
`save-image!` to a binary; boot the binary in a sub-SBCL;
inspect the tool registry, theory handle, origin index, rollback
register from inside the booted image.
**Assertion:** All four are present and contain the expected data.

### TEST-017 — Default tool-list is unchanged

**Verifies:** REQ-012.
**Type:** Example-based.
**Assertion:** `(sort (alexandria:hash-table-keys *tool-registry*)
                       #'string< :key #'symbol-name)` after default
install matches the same sorted list from a baseline harness build
without this spec.

### TEST-018 — Latency budget

**Verifies:** NFR-001.
**Type:** Performance.
**Assertion:** Over 1000 calls of a 50-form `defmethod`, p95 ≤ 100 ms
end-to-end.

### TEST-019 — Audit completeness

**Verifies:** NFR-002.
**Type:** Integration, sustained.
**Setup:** Run an agent for 30 days under representative load,
sampling tool-call frames at the agent boundary.
**Assertion:** Receipt log entry count equals frame count for
`harness-eval`, no gaps, no duplicates.

### TEST-020 — Pre-filter false-positive rate

**Verifies:** NFR-003.
**Type:** Corpus-based.
**Setup:** Run the pre-filter against the 1000-form author-validated
corpus; run the reasoner against the same forms with the floor theory.
**Assertion:** ≤ 10 forms (1%) are rejected by pre-filter where the
reasoner would have allowed.

### TEST-021 — Reasoner adjudication latency

**Verifies:** NFR-004.

### TEST-022 — Origin-index storage and query latency

**Verifies:** NFR-005, CON-005.

---

## Observability signals

### OBS-001 — `harness_eval_calls_total`

Counter; labels: `phase` (`pre-filter`/`reasoner`/`evaluated`/`rollback`),
`tag` (`ok`/`rejected`/`vetoed`/`error`/`timeout`).
Source: receipt log.
Used by: NFR-002 audit completeness check; operator dashboards.

### OBS-002 — `redefine_history_writes_total`

Counter; labels: `operator` (`agent-id`/`:operator`/`:rollback`),
`def-form` (`defmethod`/`defun`/`defparameter`/…).
Source: origin-index updates.

### OBS-003 — `rollback_register_pushes_total`

Counter; labels: `agent-id`.
Source: rollback-register pushes (does NOT count rollback executions —
those are OBS-001 with `phase=rollback`).

### OBS-004 — `harness_eval_latency_ms`

Histogram; labels: `phase`.
Source: per-call elapsed time.
Used by: NFR-001 budget verification.

### OBS-005 — `receipt_log_entries_dropped_total`

Counter (CRITICAL — should always be zero).
Source: receipt-log append failures.
Used by: NFR-002 audit completeness; alert if non-zero.

### OBS-006 — `prefilter_rejections_total`

Counter; labels: `rule`.
Source: pre-filter.
Used by: NFR-003 false-positive analysis (cross-referenced with
reasoner allow-rates on resubmitted forms).

### OBS-007 — `reasoner_adjudication_latency_ms`

Histogram; labels: `tag`.
Source: reasoner round-trip timing in the `harness-eval` handler.
Used by: NFR-004.

### OBS-008 — `redefine_history_size_bytes`

Gauge; labels: none.
Source: index walk on demand or sampled.
Used by: NFR-005.

---

## Out of scope (for this spec)

- **`harness-advise`** — see ADR-005. Candidate for v0.2.
- **`harness-redefine-method`** — see ADR-001. Subsumed by `harness-eval`.
- **Sandboxed evaluation.** Forms run in the harness process with full
  heap access. The port is a privilege escalation by design; sandboxing
  would defeat its purpose. Operators who want a sandboxed agent should
  not register `harness-eval`.
- **Permission policies.** The `:eval` keyword is defined; how policies
  combine permissions to grant or deny tools is a separate concern
  (likely a future SPEC-### on capability routing).
- **Cross-agent self-modification.** An agent cannot use `harness-eval`
  to modify another agent's image; each harness process owns its own
  heap. Multi-process self-modification (e.g., one agent shipping a
  redefinition to another via CBCL) is out of scope and would require
  its own spec.
- **Operator override of CON-002.** The pre-filter denylist is hard
  floor. Use cases that require evaluating those forms must escalate to
  REPL operator action, not agent action.

---

## Open questions

The following are unresolved in v0.1 and require human decision before
the IMPL plan converges. Each is annotated with the ADR it would
generate.

### OQ-001 — Timeout enforcement mechanism

`harness-eval` accepts a `:timeout` argument (CON-001). SBCL's
`with-timeout` interrupts via SIGALRM, which can corrupt heap state if
it fires inside a primitive. The alternative is to run the eval in a
worker thread and `terminate-thread` it on overrun — slower (~ms
overhead per call) but heap-safe.

**Recommendation:** worker thread. Cost is dominated by reasoner
round-trip (NFR-004), not thread startup.
**Generates:** ADR-006 once decided.

### OQ-002 — Package isolation

The `:package` argument defaults to `:anuna-imago-user` to keep
self-modifications out of internal namespaces by default. But the
agent can do `(in-package :anuna-imago)` inside the form, escaping the
default. Either:

(a) accept it (the port is a privilege escalation by design), or
(b) strip top-level `in-package` calls during pre-filter.

**Recommendation:** (a). Stripping is a half-measure that gives a
false sense of isolation; the agent can always cons up a symbol with
explicit package designator. Document the property; don't pretend.
**Generates:** ADR-007 once decided.

### OQ-003 — Result serialisation policy

CON-001 says values are returned as `prin1`-printed strings. Two
risks: (i) printing a circular structure hangs the printer; (ii)
printing a structure with an inappropriate `print-object` method
exfiltrates heap data the agent should not have.

**Recommendation:** bound the printer with `*print-circle* t` and
`*print-length* 100, *print-level* 10`; truncate result strings at
4 KB; no whitelist beyond that. Whitelisting types would be a
sandbox by another name.
**Generates:** ADR-008 once decided.

### OQ-004 — Rollback for non-method redefinitions

A `defparameter` or `defvar` redefinition produces an origin-index
entry but no rollback record (CON-006). `defun` redefinitions of
non-methods are similarly outside the rollback register's shape.

**Options:**
- Extend `*rollback-register*` to capture the prior `symbol-function`
  for `defun` and prior `symbol-value` for `defparameter`.
- Document the limitation and rely on the origin index for
  reconstruction.

**Recommendation:** extend for `defun`; document for `defparameter`
(parameter rollback semantics depend on initialiser side effects, no
clean general answer).
**Generates:** REQ-013 amendment once decided.

---

## Traceability summary

```
REQ-001 → TEST-001, TEST-017                       → CON-001
REQ-002 → TEST-002                                  → CON-001
REQ-003 → TEST-003, TEST-004                        → CON-001, CON-002, CON-003, CON-004
REQ-004 → TEST-005                                  → CON-002
REQ-005 → TEST-006                                  → CON-003
REQ-006 → TEST-007                                  → CON-004      → OBS-001
REQ-007 → TEST-008                                  → CON-005      → OBS-002
REQ-008 → TEST-009                                  → CON-006      → OBS-003
REQ-009 → TEST-010                                  → CON-001
REQ-010 → TEST-011..TEST-015                        → CON-002, CON-003
REQ-011 → TEST-016                                  → CON-001 + SPEC-011 CON-008
REQ-012 → TEST-017                                  → CON-001
NFR-001 → TEST-018                                                  → OBS-004
NFR-002 → TEST-019                                                  → OBS-001, OBS-005
NFR-003 → TEST-020                                                  → OBS-006
NFR-004 → TEST-021                                                  → OBS-007
NFR-005 → TEST-022                                                  → OBS-008
```

---

**END OF SPEC-012**
