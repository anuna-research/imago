# Paper scope

**Thesis (B).** Agent runtime design should commit to **operational scaffolding only** and refuse to encode assumptions about what models can or cannot do. Such assumptions age badly under the bitter lesson: today's "models can't plan, so we add a planner module" becomes tomorrow's framework migration burden. The alternative is an **amputable substrate** — a harness where every layer is redefinable in flight, the runtime artifact *is* the heap, and safety comes from invariants rather than prescriptive pipelines. anuna-imago is offered as an existence proof.

**Venue / format (p).** Position-paper PDF, 3–4 pages, for circulation. Not aimed at peer review; aimed at a small audience of AI-runtime / agent-framework engineers and researchers thinking about long-run framework design.

**Length cap.** 2200 words. Section budget:

| Section | Target |
|---|---|
| Title + abstract | 150 |
| 1. Introduction | 400 |
| 2. The bitter lesson, applied to runtimes | 400 |
| 3. The amputable substrate (principles) | 500 |
| 4. anuna-imago as existence proof | 400 |
| 5. Related stances | 250 |
| 6. Conclusion | 100 |

**Audience.** Engineers and researchers building or evaluating LLM-agent runtimes. Assume they know:
- LLM agents at the level of a tool-using chat loop
- Common framework names (LangChain, AutoGPT, smol-agents, etc.) without explanation
- Sutton's bitter lesson as a reference, but possibly not from primary

Do **not** assume they know:
- Common Lisp, CLOS, or `save-lisp-and-die`
- Defeasible logic
- Spindle / hence

These get one-paragraph treatments where unavoidable.

**Excluded scope.** Things we will NOT argue here:
- A detailed description of the SPEC-012 self-modification port. Mentioned only as a concrete instance of "safety from invariants, not pipelines."
- An empirical evaluation. The paper is a position; it offers an existence proof, not measurements.
- A defeasible logic primer or comparison.
- Performance benchmarks vs. other frameworks.
- Implementation details of identity, gateway, receipt log — these get one-line mentions.
- Migration paths from popular frameworks. Out of scope.

**Three things the paper must do:**

1. **Make the bitter-lesson connection explicit and concrete.** Show, with named examples, where current frameworks have already paid migration cost for assumptions that aged badly (planner modules, output parsers, prompt templates, hand-written tool dispatch logic).
2. **Define "amputable substrate" precisely.** Three principles: (i) every layer redefinable at runtime without restart, (ii) the artifact is the heap, (iii) safety from invariants, not pipelines. Each principle gets a paragraph of consequences.
3. **Offer anuna-imago as an existence proof, not a product pitch.** Cite scope (~4100 LOC), substrate (SBCL CLOS), and one worked example: live redefinition of `provider-stream!` surviving an image save.

**Things the paper must NOT do:**

- Critique specific frameworks by name and roast them. The argument is structural; naming examples is fine but the rhetoric should be about *categories of decision*, not "X framework is bad."
- Claim victory. This is a position to consider, not a proven win. The conclusion explicitly notes that the wager could lose: maybe model capability plateaus, in which case the prescriptive frameworks were correct to bake in scaffolding.
- Treat anuna-imago as universally adequate. It's tied to SBCL/CL, which is a real cost; we acknowledge this in §4.

**Plan adjustments needed.** With B+p chosen, three tasks in `paper-plan.spl` need shrinking or reframing:
- `task-draft-eval` → drop. Replaced by a much smaller "existence proof" component folded into `task-draft-system`.
- `task-draft-system` → renamed and reframed as `task-draft-substrate` (the amputable substrate principles) plus the existence-proof prose.
- `task-draft-background` → drop. A position paper at 3–4 pages can't afford a background section; relevant background goes inline as one-liners.

**Open questions for Hugo.**
- Title preference: working title is *"The amputable substrate: agent runtimes designed against the bitter lesson"*. Prefer something shorter / different?
- Author line: just "Hugo O'Connor" (codeberg.org/anuna), or include any collaborators / affiliations?
- License for the paper: same Apache-2.0 as the project, or CC-BY-4.0 (more conventional for prose), or CC0?
- PDF toolchain: Pandoc + LaTeX (good defaults, clean look), Tufte-CSS HTML→PDF (more visually distinctive), or LaTeX directly (heaviest, most "academic" look)?
