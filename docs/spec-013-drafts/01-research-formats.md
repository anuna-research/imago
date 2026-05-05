# Research notes: existing skill formats

Survey of skill formats in Claude Code, Codex, and hermes-agent, conducted to inform [[SPEC-013-skill-definition-port]]. Goal: identify the minimal compatible subset of frontmatter fields anuna-imago should accept and emit.

## Reference formats observed

### Claude Code (Anthropic)

- **Location convention:** `~/.claude/skills/<skill-name>/SKILL.md` (user-global) and `<project>/.claude/skills/<skill-name>/SKILL.md` (project-scoped). Example in this repo: `/Users/anuna-02/Code/anuna-imago/.claude/skills/hence/SKILL.md`.
- **Container:** one directory per skill, identified by directory name. The `SKILL.md` file is required; supporting files (references, scripts, examples) MAY accompany it in the same directory.
- **Frontmatter:** YAML, three required-ish fields observed:
  ```yaml
  name: hence
  description: This skill should be used when …
  version: 0.6.0
  ```
- **Body:** Markdown. The model reads it on activation; instructions, examples, and embedded code blocks are interpreted as guidance for the agent.

### hermes-agent (Nous Research)

- **Location convention:** `<repo>/skills/<skill-name>/SKILL.md` for first-class skills, `<repo>/optional-skills/<skill-name>/SKILL.md` for opt-in vendor skills, and `<repo>/skills/<bundle>/DESCRIPTION.md` for bundle metadata. Examples observed at:
  - `/Users/anuna-02/Code/hermes-agent/skills/yuanbao/SKILL.md`
  - `/Users/anuna-02/Code/hermes-agent/optional-skills/research/parallel-cli/SKILL.md`
- **Container:** one directory per skill, same as Claude Code.
- **Frontmatter:** YAML. Strictly a superset of the Claude Code shape:
  ```yaml
  name: parallel-cli
  description: Optional vendor skill for Parallel CLI …
  version: 1.1.0
  author: Hermes Agent
  license: MIT
  metadata:
    hermes:
      tags: [Research, Web, Search, …]
      related_skills: [duckduckgo-search, mcporter]
  ```
- **Body:** Markdown, identical structural conventions to Claude Code.

### Codex (and other agent runtimes converging on Anthropic's pattern)

- The Anthropic Skills format (YAML frontmatter + Markdown body, one-directory-per-skill, `SKILL.md` filename) has become the de-facto interchange shape across the agent-runtime ecosystem.
- hermes-agent's `optional-skills/autonomous-ai-agents/` directory shows the convergence directly: `autonomous-ai-agents-claude-code.md`, `autonomous-ai-agents-codex.md`, and `autonomous-ai-agents-opencode.md` all coexist, indicating these tools accept the same skill artefact format with at most cosmetic differences.

## Minimal compatible subset

For an artefact emitted by anuna-imago to load in any of the three runtimes above without modification, the frontmatter MUST include:

| Field | Type | Required? | Notes |
|---|---|---|---|
| `name` | string | yes | Skill identifier; MUST equal the directory name. Convention is kebab-case. |
| `description` | string | yes | One-sentence trigger condition. Used by the consuming runtime to decide when to load the skill. |

OPTIONAL but commonly emitted:

| Field | Type | Notes |
|---|---|---|
| `version` | semver string | Recommended; allows downstream pinning. |
| `metadata.<vendor>` | mapping | Vendor-specific extensions (e.g. `metadata.hermes.tags`). Should be tolerated and round-tripped but NOT load-bearing. |

Fields that some vendors emit but anuna-imago should treat as optional and inert: `author`, `license`, `tags` (top-level — hermes prefers it under `metadata.hermes.tags`).

## File / directory naming

- Skill directory name: `^[a-z][a-z0-9-]*$` (kebab-case, starts with a letter). This is the convention across all three runtimes; anuna-imago should match it for compatibility.
- Skill file: `SKILL.md` literal. (Some hermes bundles use `DESCRIPTION.md` for index-only entries; SKILL.md is the canonical content file.)

## Implications for SPEC-013

1. The on-disk format MUST be Anthropic-compatible YAML+Markdown rather than a Lisp s-exp file. This drives [[#ADR-001]] (format choice).
2. Discovery should walk a configurable root and treat any subdirectory containing a `SKILL.md` as a skill. Drives [[#ADR-002]] (discovery semantics).
3. Round-trip preservation of unknown frontmatter fields is required for cross-runtime portability — anuna-imago must not strip `metadata.hermes.tags` or similar even if it does not interpret them.
4. Body content is Markdown text, not executable code. The "self-evolution" framing must distinguish *skill bodies* (declarative guidance, no code execution at load) from *harness-eval forms* (Lisp source, executed under safety gates). Drives [[#ADR-003]] (safety treatment).

## Open questions surfaced by research

- **OQ-001 (resolution order).** When the same skill name exists in both project-scoped (`./skills/`) and user-global (`~/.imago/skills/`) directories, which wins? Claude Code precedent: project-scoped wins; user-global is fallback. Codify this or leave configurable?
- **OQ-002 (frontmatter strictness).** Should anuna-imago reject skills whose frontmatter contains fields it does not recognise, or pass them through inertly? Anthropic-compatible runtimes pass through; we should match.
- **OQ-003 (skill bodies and the floor).** Skill bodies are Markdown by design — no execution. But a skill body that *instructs* the agent to call `harness-eval` with a forbidden form would still be intercepted by the existing floor invariants on the eventual `harness-eval` call. The skill itself is therefore *outside* the harness-eval safety surface, and its risk surface is purely "does it influence the agent toward bad calls?" This question is taken up in [[#ADR-003]] but the framing should be in scope for spec review.
