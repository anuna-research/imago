# Paper outline

**Title (working).** *The amputable substrate: agent runtimes designed against the bitter lesson.*

**Length cap.** ~2200 words across 6 sections + abstract. Per-paragraph claims below — not "discuss X" but "we show X."

---

## Abstract — 150 words

- Sentence 1: Most LLM-agent frameworks embed assumptions about what models can or cannot do — planner modules, prompt templates, output parsers, hand-written tool dispatch.
- Sentence 2: Such assumptions age badly under Sutton's bitter lesson: model capability climbs, scaffolding becomes obsolete, and the framework's value collapses into migration burden.
- Sentence 3: We argue agent runtimes should commit to **operational scaffolding only** — supervision, identity, audit, capability routing — and treat every other layer as an *amputable substrate* the user can redefine in flight.
- Sentence 4: Three principles follow: (i) every layer redefinable at runtime without restart, (ii) the runtime artifact IS the heap, (iii) safety comes from invariants, not pipelines.
- Sentence 5: We offer anuna-imago, a ~4100-LOC SBCL Common Lisp harness, as an existence proof — and acknowledge the wager: if model capability plateaus, the prescriptive frameworks were correct.

---

## §1. Introduction — 400 words

- ¶1 (~80 words). The framing question: *what should an LLM-agent runtime commit to?* Today's mainstream answer — give the user a planner, a memory module, a tool selector, a prompt template engine — implicitly bets that current model limitations will persist. State the thesis: that bet has been losing for at least three years and the bitter lesson predicts it will continue to lose.
- ¶2 (~100 words). Concrete examples *without naming names*: explicit-planning modules (now superseded by chain-of-thought tool-use), regex output parsers (now superseded by structured outputs), prompt templating engines (now near-empty wrappers), retrieval-augmented memory abstractions (now contested by long-context). Three years of agent frameworks have already lived through one round of "the model now does X natively" obsoleting their abstractions. Predict the fourth round.
- ¶3 (~100 words). The alternative: refuse to encode capability assumptions at the framework layer. Commit to operational scaffolding — the *boring* parts that don't depend on what the model can do. Supervision, audit, identity, capability routing, image distribution, runtime safety invariants. These are about how the agent process *exists and is governed*, not about what work it does.
- ¶4 (~120 words). Preview of the three principles (named, one sentence each) and the anuna-imago existence proof. Set up the structure: §2 makes the bitter-lesson connection concrete, §3 defines the substrate, §4 offers the existence proof, §5 positions, §6 concludes.

---

## §2. The bitter lesson, applied to runtimes — 400 words

- ¶1 (~100 words). State Sutton's lesson [Sutton 2019]: general methods that scale with compute beat hand-engineered ones. Acknowledge that Sutton wrote about *research methods*, not *engineering frameworks*. Argue the lesson transfers: framework abstractions that compensate for model limitations are themselves hand-engineering.
- ¶2 (~120 words). Three concrete framework-decision-that-aged-badly examples, each one paragraph-line:
  (a) Planner modules → tool-using chain-of-thought has eaten this scope.
  (b) Output parsers → structured outputs / JSON mode have made parser libraries near-obsolete in months.
  (c) Prompt-templating engines → prompt-as-database is a thinner abstraction than expected once instruction-following improved.
- ¶3 (~100 words). Counterargument and rebuttal: "but every framework needs *some* opinion." Yes, but the opinion should be about *operational concerns* (process supervision, audit, distribution) which are stable across model generations, not *capability concerns* (what models need help doing) which are not.
- ¶4 (~80 words). The migration cost is real and underdiscussed. Each obsoleted abstraction = engineering teams either rewriting against the new framework idiom or carrying dead weight. The cost compounds. A framework that refuses to take stand-in positions on model capability *cannot owe* this migration debt.

---

## §3. The amputable substrate — 500 words

- ¶1 (~80 words). Define the term. *Amputable substrate*: a runtime where every layer is removable, replaceable, or redefinable in flight. The framework provides infrastructure; the user provides the choices the framework would otherwise have made for them. Name the three principles to be developed.
- ¶2 — Principle 1: every layer redefinable at runtime without restart (~140 words).
  - Claim: late binding everywhere — methods are dispatch points, not call sites. The lineage runs through McCarthy's metacircular `eval` [McCarthy 1960] and its descendants in Lisp and Smalltalk.
  - Consequence: when a built-in turns out to encode an obsolete assumption, you redefine it at the live REPL instead of filing a framework migration ticket.
  - Consequence: the framework refuses to bake "the right way to do X" into a closed implementation. Instead it exposes the seams where X is dispatched.
  - Concrete: in CLOS, `defmethod` is a runtime operation. Tool dispatch, hook chain, provider streaming — all method calls — are all redefinable.
- ¶3 — Principle 2: the runtime artifact IS the heap (~140 words).
  - Claim: distribution is image distribution. The deployed binary is a frozen heap, including any patches the user applied at the live REPL.
  - Consequence: the redefined-in-flight semantics survives deployment. There is no "production differs from dev because dev redefined some methods."
  - Consequence: the framework cannot impose a build pipeline whose assumptions might age out — there is no build pipeline, only the heap.
  - Concrete: SBCL `save-lisp-and-die` produces a single-file executable; redefined methods are in the saved heap [Steele & Gabriel 1996].
- ¶4 — Principle 3: safety from invariants, not pipelines (~140 words).
  - Claim: safety is not "do these checks in this order"; it is "these statements about the system must always hold."
  - Consequence: the framework does not own the safety pipeline. The user authors invariants (in defeasible logic, in this implementation) and the framework gates only on whether invariants are violated.
  - Consequence: when the model gains a new capability, the invariants don't need to change. A pipeline-based safety story, by contrast, gets longer with every new capability surface.
  - Concrete: anuna-imago's SPEC-012 self-modification port queries a Spindle theory at every `harness-eval` call; the theory is the entire safety contract.

---

## §4. anuna-imago as existence proof — 400 words

- ¶1 (~80 words). State scope: ~4100 LOC of harness, ~3340 LOC of tests, single SBCL Common Lisp source tree. The implementation is small enough to read in an afternoon. The artifact is offered as a demonstration that the principles are coherent, *not* as a product pitch — anuna-imago has costs (CL/SBCL lock-in, no Python ergonomics, no JS ecosystem) that disqualify it from most teams' use.
- ¶2 (~140 words). Worked example: live redefinition of `provider-stream!` surviving an image save. Show ~10 lines of REPL transcript: build agent against stub provider, ask, redefine the provider's `stream!` method to produce different output, ask again (new behavior, same process), `save-image!` to a binary, run binary on the command line, observe the redefined behavior. The point: the redefinition didn't go through any framework migration ticket. It was a one-line REPL operation.
- ¶3 (~100 words). Brief mention of the SPEC-012 self-modification port as the §3-Principle-3 instance. Three-layer safety stack: pre-filter denylist, defeasible-logic reasoner querying a Spindle theory, handler with rollback register. Cite the published EXPERIMENT-LOG.md showing GLM 5.1 self-redefining 18 symbols across 6 turns to add persistent memory, with 3 legitimate vetoes from the floor invariants.
- ¶4 (~80 words). Honest costs. CL/SBCL is a real lock-in: small ecosystem, sharp learning curve, hiring difficulty. anuna-imago's argument is structural — *some* substrate that supports these principles must exist — not that *this* substrate is the right one for everyone.

---

## §5. Related stances — 250 words

- ¶1 (~80 words). The Lisp / Smalltalk-image lineage [McCarthy 1960; Goldberg & Robson 1983]. Same substrate spirit (eval/apply self-reference, late binding, image-as-artifact); applied to *integrated development*, not LLM-agent runtimes. We claim the spirit transfers and the bitter lesson makes it newly important.
- ¶2 (~80 words). Anthropic's "Building Effective Agents" [Anthropic 2024] argues empirically that simpler agent loops outperform complex multi-agent orchestration frameworks. We arrive at a convergent practical stance via a different argument (bitter-lesson → substrate). Both directions point at the same conclusion.
- ¶3 (~90 words). The Erlang/OTP supervision tradition [Armstrong 2003]. anuna-imago's `make-supervisor` is a direct CLOS port of Armstrong's one-for-one supervisor. The contribution is not the supervisor — the contribution is *limiting framework scope to such established prior art* and pushing everything else to user code.

---

## §6. Conclusion — 100 words

- ¶1 (~100 words). Restate the position concisely: agent runtimes should commit to operational scaffolding only; everything else should be amputable. Acknowledge the wager: if model capability plateaus in the next 3 years, prescriptive frameworks were the right call and we paid for under-engineering. If capability continues climbing, prescriptive frameworks pay migration debt forever and the substrate position wins by attrition. Close with the artifact link and an invitation to amputate it.

---

## Key claims being made (summary, for Hugo's vetting)

1. Three current framework abstractions have already aged badly: planner modules, output parsers, prompt templates. (§2)
2. Three principles characterise an amputable substrate: live redefinition, image-as-artifact, invariant-based safety. (§3)
3. anuna-imago is an existence proof of a coherent runtime under those principles in ~4100 LOC. (§4)
4. The position converges with Anthropic's "Building Effective Agents" engineering stance via independent reasoning. (§5)
5. The wager could lose if model capability plateaus. (§6)

If any of these doesn't survive Hugo's claims-review, the section structure stays but specific paragraphs shift.

## Word budget check

| Section | Target | Cumulative |
|---|---:|---:|
| Abstract | 150 | 150 |
| §1 Intro | 400 | 550 |
| §2 Bitter lesson | 400 | 950 |
| §3 Substrate | 500 | 1450 |
| §4 Existence proof | 400 | 1850 |
| §5 Related | 250 | 2100 |
| §6 Conclusion | 100 | 2200 |

Within the 2200-word cap. PDF rendering at 11pt one-column ≈ 350 words/page → 6.3 pages. Slight risk of overshoot (target was 3-4 pages); §3 is the longest and could be trimmed to 400 if needed. Hugo to call.
