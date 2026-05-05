# Architecture decisions (ADR-### entries)

Load-bearing design decisions for the [[SPEC-013-skill-definition-port|skill definition port]]. Each ADR records the options considered, the choice taken, and the consequences.

---

## ADR-001: On-disk format — Anthropic-compatible YAML+Markdown

**Context.** anuna-imago's existing artefacts (the `harness-eval` audit log, the rollback register, the receipt log) are Lisp-native. A Lisp s-expression skill format would be the path of least implementation resistance. However, the principal value of skills as an accumulation surface is that they portably encode agent guidance across runtimes — claude-code, codex, hermes-agent, opencode all converge on the [[Anthropic Skills]] format documented in [[#01-research-formats]].

**Options considered.**

1. **Lisp s-expression skill files** (`SKILL.lisp` with `(defskill … :name … :description … :body "…")`). Pros: trivial to parse with the existing reader; integrates naturally with the harness. Cons: incompatible with every other agent runtime; defeats the disk-persistent accumulation purpose; would force users to maintain two parallel skill libraries if they use any other tool.

2. **JSON skill files** (`skill.json` with `{ "name": …, "description": …, "body": … }`). Pros: structured, widely supported. Cons: incompatible with the de-facto cross-runtime standard; awkward for prose bodies (newlines, escapes).

3. **Anthropic-compatible YAML + Markdown** (`SKILL.md` with frontmatter + body). Pros: portable; matches the existing tooling ecosystem; prose bodies are natural in Markdown. Cons: requires a YAML parser dependency in anuna-imago.

**Decision.** Option 3. The cross-runtime portability is the load-bearing property; format choice should serve it.

**Consequences.**

- A YAML 1.2 subset parser must be added. The minimal subset we need (top-level mapping with string keys and string/number/boolean/list/nested-mapping values) is well-served by `cl-yaml` or a small purpose-built parser; we should prefer the smallest workable dependency.
- The Markdown body is treated as opaque text by anuna-imago — we do not need a Markdown parser for execution. A Markdown parser is only needed for cosmetic operations (e.g. extracting the first heading); these are out of scope for v0.1.
- Round-trip preservation of unknown frontmatter fields ([[#REQ-008]]) becomes a parser-level requirement: we cannot reduce frontmatter to a fixed CL `defclass` because vendor extensions must round-trip verbatim.

Trace: implements [[#REQ-001]], [[#REQ-008]]; constrains the implementation of [[#CON-001]].

---

## ADR-002: Skill discovery — project-scoped first, user-global second

**Context.** Multiple agents on the same machine, and multiple projects within the same checkout, will accumulate overlapping skill libraries. A single global skill root creates collisions and prevents per-project skill curation. Multiple roots without a deterministic resolution order create accidental shadowing bugs.

**Options considered.**

1. **Single user-global root** (`~/.imago/skills/`). Simple. Forces all skills into one namespace.

2. **Single project-local root** (`./.imago/skills/`). Per-project isolation, but loses the cross-project benefit (a user-curated `email-extract` skill is unavailable in a sibling project).

3. **Ordered list of roots, project-first** (`./.imago/skills/`, then `~/.imago/skills/`). Project-scoped skills shadow user-global ones; same-name skills resolve deterministically; configuration is explicit and overridable. Matches [[Claude Code]]'s precedent.

**Decision.** Option 3. The project-first order matches user expectations (the project's skill is the one the user wants when working on that project) and matches the convention agents already encounter elsewhere.

**Consequences.**

- `*skill-roots*` is a list, default `'(#P".imago/skills/" #P"~/.imago/skills/")`. Operators can override, including injecting site-wide roots between project and user.
- A `*skill-shadow-log*` records cases where a skill of the same name exists in a later root, so an operator can see what's hidden ([[#OBS-005]]).
- The empty-roots edge case (neither directory exists) loads zero skills without error.
- Symbolic links are followed once; cycles are detected and broken at the second visit (a defensive measure — the underlying filesystem call provides this guarantee on supported platforms).

Trace: implements [[#REQ-003]], [[#REQ-011]]; constrains [[#CON-003]].

---

## ADR-003: Safety treatment — skills are opaque text, not execution

**Context.** The most consequential design question for the port is whether skill bodies are execution surfaces. A skill body is, in principle, a string of guidance for the agent. But the agent is presumed untrusted; if a skill body says "now call `harness-eval` with `(unintern …)`", the framework must not honour that instruction blindly.

The pre-existing `harness-eval` safety stack ([[ADR-012-self-mod-adversarial-review|three-layer floor]]) already covers this: regardless of *why* the agent calls `harness-eval`, the call is intercepted and gated. A skill that influences the agent toward a forbidden call is therefore not, in itself, a new attack surface — the existing floor is the relevant defence.

The question is whether to introduce an *additional* floor at skill-load time. Two options:

**Options considered.**

1. **Skills as opaque text; rely on existing floor.** No skill-load gate. Bodies are stored verbatim and presented to the agent as guidance. The agent's resulting tool calls go through the existing safety stack.

2. **Skill-load floor.** A new defeasible-logic theory consulted at install time, with rules over body content (e.g. *forbid skill bodies that mention `unintern`*).

**Decision.** Option 1.

**Consequences.**

- The defended surface is unchanged: every dangerous action still passes through the `harness-eval` floor on the way to taking effect. A skill that *describes* a dangerous action without *invoking* one is harmless until the agent acts on it, at which point the existing gate applies.
- Skill content is fully expressive — guidance for the agent can include exact code snippets, even ones the floor would refuse, without the install path needing to second-guess intent. This matches how Claude Code, hermes-agent, and other ecosystems treat skill bodies.
- If empirical evidence (see [[#OBS-006]]) shows that skill bodies are routinely steering the agent toward calls that the floor blocks, we should add a *body-influence reasoner* in v0.2 — but as a teaching layer (the agent gets a teaching hint when it acts on guidance that would be vetoed), not as a load-time filter.
- Adversarial review should specifically probe the boundary: "can a skill's prose, combined with model compliance pressure, induce calls that the harness-eval floor *would* block but somehow does not?" If the answer is non-trivial, we revisit. ([[#TEST-018]], [[#TEST-019]], [[#TEST-020]]).
- This decision is the most reversible of the four ADRs: a load-time floor can be added later without changing the on-disk format or the contracts.

Trace: implements [[#REQ-010]]; gated on adversarial review ([[#TEST-018]]–[[#TEST-020]]).

---

## ADR-004: Namespace — skills and tools share no naming pool

**Context.** Skills and tools are both agent-facing surfaces, both with names. Two sane choices: merge them into one namespace (a name `foo` is either a tool *or* a skill but not both), or keep them disjoint (a tool `foo` and a skill `foo` may coexist).

**Options considered.**

1. **Shared namespace.** Pros: simpler mental model — the agent sees one set of names. Cons: forces collision detection across two registration paths; a third-party skill download could clobber an installed tool (or vice versa); the merge produces no functional benefit because the call sites are separate.

2. **Disjoint namespaces.** Pros: independent evolution; no surprise clobbering across the install paths; matches the conceptual separation (tools are CL functions registered by `define-tool`; skills are Markdown text registered by `harness-define-skill`). Cons: the agent must distinguish via context which surface a name refers to.

**Decision.** Option 2. The conceptual separation is real and worth preserving.

**Consequences.**

- `harness-list-tools` and `harness-list-skills` are the two enumeration surfaces; neither sees the other's entries.
- A skill *can* describe how to use a tool of the same name without ambiguity, since the call sites are different.
- Documentation should make the distinction explicit so the agent does not conflate `(harness-describe-tool 'foo)` with `(harness-describe-skill 'foo)`.

Trace: implements [[#REQ-012]].
