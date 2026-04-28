# Literature review

A short position paper at 3–4 pages cannot afford a long bibliography. The aim
here is to identify the strongest 3 prior works the paper should explicitly
position against, plus a smaller set of supporting citations for one-line
mentions.

**Confidence convention.** Each entry is tagged:
- ⭐ — high-confidence existing work I can cite without further verification.
- ⚠ — exists but I'm unsure of exact title/year; needs Hugo's eyeballs or a
  quick search before final BibTeX.
- 💭 — pointer in a direction the paper might benefit from; specific citation
  TBD by Hugo if he wants to include it.

---

## Thread 1 — The bitter lesson and capability scaling

### ⭐ Sutton, R. (2019). "The Bitter Lesson."

Online essay at `incompleteideas.net/IncIdeas/BitterLesson.html`. The canonical
reference. Sutton's argument: general methods that scale with compute have
historically beaten domain-specific hand-engineering across game-playing,
speech, vision. The paper cites this directly in §1 and §2 as the
philosophical foundation for refusing to embed model-capability assumptions
in framework code. **Position to:** treat as accepted. The paper extends the
lesson from research methods to *runtime architecture* — a step Sutton's essay
doesn't take but doesn't preclude.

### 💭 Hooker, J. N. (1995). "Testing heuristics: We have it all wrong."

A *Journal of Heuristics* paper arguing that empirical AI research too often
benchmarks specific implementations rather than the underlying ideas. Tangent
to our argument; possibly worth a footnote when we say "frameworks are
betting against scaling but framing it as engineering pragmatism." Skip
unless space allows.

---

## Thread 2 — The Smalltalk-image / Lisp-Machine lineage

### ⭐ Goldberg, A. & Robson, D. (1983). *Smalltalk-80: The Language and its Implementation.*

The "Blue Book" — primary source for the image-based development model, where
the runtime artifact IS the heap. anuna-imago's `save-lisp-and-die` lineage
runs through here. **Position to:** kindred spirit, different problem.
Smalltalk argued that integrated environments + image distribution are the
right *development experience*; we argue they're the right *agent runtime
architecture*. The argument-for-substrate is the same; the consumer is
different.

### ⚠ Bobrow, D. G. & Stefik, M. (1986). "Perspectives on artificial intelligence programming."

Likely *Science* 231(4741):951–957. Surveys why Lisp Machines were the
serious AI workstations of the era — image dumps, late binding, REPL
interactivity. Worth one-line citation in §5 alongside the Smalltalk
reference, framing the substrate spirit as having an established AI lineage.

### ⭐ Steele, G. & Gabriel, R. (1996). "The evolution of Lisp."

In *History of Programming Languages II*, ACM Press. The "worse is better"
discussion and the broader story of how Common Lisp's CLOS late binding came
to be. Useful one-line citation for the "every layer is redefinable" principle.

---

## Thread 3 — Capability routing and supervision (operational scaffolding)

### ⭐ Armstrong, J. (2003). "Making reliable distributed systems in the presence of software errors."

PhD thesis, KTH. The Erlang/OTP supervision-tree model. anuna-imago's
`make-supervisor` / `spawn-agent!` is a direct CLOS port of this pattern.
**Position to:** ancestor. We borrow the supervision skeleton and add nothing
to it; that is the point. The paper notes that operational scaffolding has
established prior art and the contribution is to *limit framework scope to
that prior art* — not to invent new agent abstractions.

### 💭 Miller, M. S. (2006). "Robust Composition: Towards a Unified Approach to Access Control and Concurrency Control."

PhD dissertation, Johns Hopkins. The capability-based security tradition
(E language, object-capability model). anuna-imago's per-agent capability
strings are a thin shadow of this. Cite if the paper has space for one line
on capabilities; otherwise drop.

---

## Thread 4 — Critiques of LLM-agent frameworks

### ⭐ Anthropic (2024). "Building Effective Agents."

The December 2024 engineering blog post arguing that simpler agent loops
(plain tool-use, no orchestration framework) often outperform complex
multi-agent architectures. URL: `anthropic.com/engineering/building-effective-agents`.
**Position to:** convergent stance from a different angle. Anthropic argues
the case empirically (their own measurements); we argue it structurally (the
bitter lesson predicts it). The paper notes both arguments point the same
direction.

### ⚠ Willison, S. (2024–2025). Multiple posts on `simonwillison.net` critiquing agent abstractions.

Specifically posts arguing that "agents" without precise definition is a
weak abstraction, and that tool-use loops do most of the useful work that
"agent frameworks" claim. Cite one post; Hugo to pick the strongest. Likely
candidates: the "What is an agent?" post, the "Tools" series.

### 💭 Karpathy, A. (2024). Twitter / X posts on "software 2.0" → "software 3.0" framing.

Andrej Karpathy's framing that prompt-as-program is a transitional artifact
and that future systems will route around prompt engineering. Tangent to
our argument; cite only if space and only via a stable URL (Twitter is
unreliable for citations). Skip is fine.

---

## Thread 5 — Defeasible logic (one-line mention only)

### ⭐ Antoniou, G. (1997). *Nonmonotonic Reasoning.* MIT Press.

Standard textbook reference for defeasible logic. The paper mentions
defeasible logic in §4 only as the formalism behind anuna-imago's
self-modification floor invariants. One citation, no exposition.

### 💭 Maher, M. J. (2001). "Propositional defeasible logic has linear complexity." *Theory and Practice of Logic Programming* 1(6):691–711.

The complexity result behind why Spindle is fast enough to be in the request
path. Cite only if the existence-proof section ends up needing to defend
"can you really run a logic engine per tool call" — likely not at this
length.

---

## Strongest 3 to position against, with one-line distinctions

1. **Sutton (2019)** — The bitter lesson. We extend it from research methods
   to runtime architecture; he doesn't make this step explicitly.
2. **Goldberg & Robson (1983)** — Smalltalk image. Same substrate spirit;
   we apply it to LLM-agent runtimes specifically and argue the bitter lesson
   makes it newly important.
3. **Anthropic (2024)** — "Building Effective Agents." Convergent practical
   stance; we provide the theoretical-framework argument (bitter lesson →
   amputable substrate).

## Open questions for Hugo at claims-review time

- Are there agent-framework critiques you'd cite that I'm missing? (I tried
  to avoid roasting specific frameworks by name; tell me if a particular
  paper or post is a load-bearing reference for §2.)
- Anthropic's "Building Effective Agents" — load-bearing, or a tangent?
  I'm currently planning to cite it twice (§2 framework critiques, §5
  related stances). Could collapse to one.
- The Lisp-Machine references (Bobrow & Stefik) — vouch or drop?
- Anything from the agent-safety literature (e.g., Constitutional AI,
  capability-control papers) you want gestured at? I currently leave them
  out because §3's "safety from invariants" is meant as a *substrate*
  position, not an *alignment* one. But if you'd rather flag the
  connection, easy to add.
