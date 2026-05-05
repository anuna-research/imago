---
id: SPEC-013
title: Skill definition port — agent-curated, cross-runtime-compatible skills
status: draft
version: 0.1.0
created: 2026-05-05
author: Hugo O'Connor
spec-of: anuna-imago
implements-plan: plan.spec-013.spl
license: Apache-2.0
---

# SPEC-013: Skill definition port

> Agent-curated, file-system-persistent, cross-runtime-compatible skill artefacts for [[anuna-imago]]. Companion surface to [[SPEC-012-self-modification-port|the harness-eval port]]: where SPEC-012 lets the agent rewrite live methods under floor invariants, this port lets the agent write **named, persistent guidance** the harness re-discovers on every boot.

## Information table

| Field | Value |
|---|---|
| **Document ID** | SPEC-013 |
| **Title** | Skill definition port |
| **Status** | draft |
| **Version** | 0.1.0 |
| **Created** | 2026-05-05 |
| **Author** | Hugo O'Connor |
| **Spec of** | [[anuna-imago]] |
| **Plan** | [[plan.spec-013]] |
| **Builds on** | [[SPEC-011-anuna-imago-runtime|SPEC-011]] (live runtime), [[SPEC-012-self-modification-port|SPEC-012]] (existing safety stack) |
| **Compatible with** | [[Anthropic Skills]] format used by [[Claude Code]], [[Codex]], [[hermes-agent]], [[opencode]] |

## Status: DRAFT

This specification is a draft pending [[#review-spec|Hugo's review]]. Three open questions are explicitly marked at [[#Open questions]]; the spec status changes to `approved` only after their resolution and any consequent revisions.

---

## 1. Background

Anuna-imago has a heap-persistent self-evolution surface ([[SPEC-012-self-modification-port|SPEC-012]]): the agent calls `harness-eval` with a Common Lisp form, the form is gated by [[ADR-012-self-mod-adversarial-review|the three-layer floor]], and successful redefinitions land in the live image. Captured via `save-image!`, those redefinitions persist into the deployed binary.

The empirical [[architecture/EXPERIMENT-LOG|experiment log]] and the [[modular-self-evolving|companion position paper]] both demonstrate the headline strength of this surface (the agent can extend its own runtime under safety gates) and surface its gap: heap-persistent evolution survives only when the operator captures an image. If the process exits before `save-image!`, the agent's work is lost. The agent has no autonomous way to persist named, separable artefacts of its experience across sessions.

Adjacent agent runtimes — [[Claude Code]], [[Codex]], [[hermes-agent]] — converge on a different mechanism that closes this gap: file-system-persistent **skills**. A skill is a directory containing a `SKILL.md` file with YAML frontmatter (at minimum `name` and `description`) and a Markdown body. The agent (or the user) writes a skill; the runtime re-discovers it at boot; the skill is then available as named, separable guidance.

The drafts that informed this spec are:

- [[#01-research-formats|Format survey]] — three reference runtimes, the minimal compatible subset.
- [[#02-requirements|Requirements]] — twelve REQ-### entries.
- [[#03-nfrs|Non-functional requirements]] — six NFR-### entries.
- [[#04-contracts|Contracts]] — six CON-### entries (the format itself plus the five tools).
- [[#05-adrs|ADRs]] — four design decisions.
- [[#06-tests|Tests]] — twenty-eight TEST-### entries with explicit Validates: REQ-### attribution.
- [[#07-observability|Observability]] — seven OBS-### signals.

## 2. Goal

Add a **skill definition port** to anuna-imago that:

1. Lets the agent define, list, inspect, install, and uninstall named skills via tool calls. ([[#REQ-002]], [[#REQ-004]], [[#REQ-005]])
2. Persists each skill as an [[Anthropic Skills]]-compatible artefact on disk: one directory, one `SKILL.md` with YAML frontmatter and Markdown body. ([[#REQ-001]], [[#CON-001]], [[#ADR-001]])
3. Re-discovers all skills at every boot from a configured list of roots, with deterministic resolution order. ([[#REQ-003]], [[#REQ-011]], [[#ADR-002]])
4. Treats skill bodies as opaque guidance text — no execution at load, install, or define. The agent's resulting tool calls remain gated by the existing floor. ([[#REQ-010]], [[#ADR-003]])
5. Round-trips unknown frontmatter fields verbatim so anuna-imago's skills load in other runtimes and vice versa. ([[#REQ-008]])

## 3. Non-goals

- Executing skill bodies. They are text. (See [[#ADR-003]].)
- Running the YAML+Markdown skill format through the [[ADR-012-self-mod-adversarial-review|harness-eval floor]] at load time. The relevant floor still gates every dangerous *call* the agent makes after consulting a skill.
- Migrating or auto-importing skills from other agent runtimes. Compatibility is at the file format level; users place skills in `*skill-roots*` themselves.
- A registry of trusted skill sources, signing, or distribution. Out of scope for v0.1.
- A Markdown parser. Bodies are stored as opaque UTF-8 text.

## 4. Requirements

The full REQ-### catalogue is in [[#02-requirements]]. Summary index:

| ID | Title | Trace |
|---|---|---|
| [[#REQ-001]] | Anthropic-compatible on-disk format | [[#TEST-001]], [[#TEST-002]], [[#CON-001]] |
| [[#REQ-002]] | Agent-driven definition | [[#TEST-003]], [[#TEST-004]], [[#CON-002]] |
| [[#REQ-003]] | Discovery at boot | [[#TEST-005]], [[#TEST-006]], [[#CON-003]] |
| [[#REQ-004]] | Listing and inspection | [[#TEST-007]], [[#CON-004]], [[#CON-005]] |
| [[#REQ-005]] | Live install without restart | [[#TEST-008]], [[#TEST-009]], [[#CON-006]] |
| [[#REQ-006]] | Naming constraints | [[#TEST-010]], [[#TEST-011]] |
| [[#REQ-007]] | Body validation | [[#TEST-012]], [[#TEST-013]] |
| [[#REQ-008]] | Round-trip unknown fields | [[#TEST-014]], [[#TEST-015]] |
| [[#REQ-009]] | Persistence semantics | [[#TEST-016]], [[#TEST-017]] |
| [[#REQ-010]] | Safety surface | [[#TEST-018]], [[#TEST-019]], [[#TEST-020]] |
| [[#REQ-011]] | Resolution order across roots | [[#TEST-021]] |
| [[#REQ-012]] | Tool-registry namespace separation | [[#TEST-022]] |

## 5. Non-functional requirements

Full catalogue in [[#03-nfrs]]. Summary:

| ID | Title | Threshold | Verifies |
|---|---|---|---|
| [[#NFR-001]] | Boot discovery latency | p95 ≤ 200 ms @ 100 skills | [[#TEST-023]] |
| [[#NFR-002]] | `define` end-to-end latency | p95 ≤ 50 ms @ 8 KB body | [[#TEST-024]] |
| [[#NFR-003]] | Max body size | 65 536 chars | [[#TEST-013]], [[#TEST-025]] |
| [[#NFR-004]] | Name length | 1–64 chars | [[#TEST-011]], [[#TEST-026]] |
| [[#NFR-005]] | Skills per root | ≥ 1 000 | [[#TEST-027]] |
| [[#NFR-006]] | Per-skill footprint | ≤ 1 KB minimum | [[#TEST-028]] |

## 6. Contracts

Full CON-### catalogue in [[#04-contracts]]. Summary:

| ID | Surface | Implements |
|---|---|---|
| [[#CON-001]] | The `SKILL.md` artefact format | [[#REQ-001]], [[#REQ-006]]–[[#REQ-008]] |
| [[#CON-002]] | `harness-define-skill` | [[#REQ-002]], [[#REQ-005]]–[[#REQ-007]] |
| [[#CON-003]] | `discover-skills!` boot path | [[#REQ-003]], [[#REQ-011]] |
| [[#CON-004]] | `harness-list-skills` | [[#REQ-004]] |
| [[#CON-005]] | `harness-describe-skill` | [[#REQ-004]] |
| [[#CON-006]] | `harness-install-skill`, `harness-uninstall-skill` | [[#REQ-005]] |

## 7. Architecture decisions

Full ADR-### catalogue in [[#05-adrs]]. Summary:

| ID | Title | Decision |
|---|---|---|
| [[#ADR-001]] | On-disk format | Anthropic-compatible YAML+Markdown |
| [[#ADR-002]] | Discovery resolution order | Project-scoped first, user-global second |
| [[#ADR-003]] | Safety treatment of skill bodies | Opaque text; rely on existing harness-eval floor |
| [[#ADR-004]] | Namespace | Tools and skills share no naming pool |

## 8. Tests

Full catalogue in [[#06-tests]]. Twenty-eight tests covering positive, negative-input, negative-output, boundary, capacity, and adversarial categories. Every REQ has at least one TEST per applicable type per [[PROTO-001#Requirement-Targeted Test Decomposition]].

Critical safety-surface tests are [[#TEST-018]], [[#TEST-019]], and [[#TEST-020]] (the latter is adversarial, requiring fresh-context generation per [[PROTO-001#Adversarial Review]]).

## 9. Observability

Full catalogue in [[#07-observability]]. Seven OBS-### signals covering boot timing, define timing, registered count, body-size distribution, shadowed-skill log, skill-influence trace (v0.2 placeholder), and validation-failure rate.

## 10. Open questions

Three questions are explicitly marked for Hugo's review before the spec advances to `approved`:

### OQ-001: Resolution order across roots — codified or configurable?

The current [[#ADR-002]] specifies project-first, user-global-second as a hard-coded resolution order. An alternative is to leave `*skill-roots*` user-configurable with no default order at all (operators set the list explicitly). The hard-coded default matches Claude Code and is friendlier for first-time users; the fully configurable approach is more flexible.

**Recommendation:** keep the hard-coded default *and* allow operator override. Both modes coexist; the default is what's documented.

### OQ-002: Frontmatter strictness — pass-through or known-keys-only?

[[#REQ-008]] requires round-trip preservation of unknown fields. An alternative position is strict mode: anuna-imago rejects skills with unrecognised frontmatter to prevent silent ecosystem drift. Anthropic-compatible runtimes pass through; matching them is the default. A strict mode could be available as a parameter `*skill-strict-frontmatter*` for operators who want to enforce a fixed schema.

**Recommendation:** default pass-through (matches ecosystem); strict mode opt-in.

### OQ-003: Skill bodies and the floor — does v0.1 ship a body-influence reasoner?

[[#ADR-003]] argues no: skills are opaque text and the existing floor catches dangerous *calls*, not dangerous *prose*. [[#OBS-006]] is a v0.2 placeholder for measuring whether skill bodies routinely steer the agent toward floor-blocked calls; if the empirical answer is yes, a body-influence reasoner becomes a v0.2 addition. This is the most consequential of the three OQs because it determines whether the implementation has a single safety gate (existing floor) or two.

**Recommendation:** v0.1 ships [[#ADR-003]] as written. v0.2 revisit conditional on [[#OBS-006]] data.

## 11. Status lifecycle

| Status | Trigger |
|---|---|
| `draft` | Current. Spec is reviewable but not approved. |
| `approved` | After [[#review-spec|Hugo's review]] and OQ resolution. |
| `implementing` | When a follow-on plan claims `task-implement-deferred`. |
| `implemented` | After implementation lands in `src/skills.lisp` (or equivalent) and all TESTs pass. |

## 12. Appendices

### Appendix A: Drafts

The drafts that fed this assembly live in `docs/spec-013-drafts/` and are co-committed with this spec for traceability:

- [[#01-research-formats|01-research-formats.md]]
- [[#02-requirements|02-requirements.md]]
- [[#03-nfrs|03-nfrs.md]]
- [[#04-contracts|04-contracts.md]]
- [[#05-adrs|05-adrs.md]]
- [[#06-tests|06-tests.md]]
- [[#07-observability|07-observability.md]]

These are working documents. The canonical content is in this spec; drafts are retained for adversarial-review traceability.

### Appendix B: Related specs

- [[SPEC-011-anuna-imago-runtime]] — the underlying runtime (supervisor, agent, hooks, tools).
- [[SPEC-012-self-modification-port]] — the heap-persistent self-evolution surface; this spec is its disk-persistent complement.
- [[plan.spec-013]] — the implementation plan coordinating this spec's drafting and (deferred) implementation.

### Appendix C: Compatibility matrix

| Field | Source | anuna-imago treatment |
|---|---|---|
| `name` | required | required |
| `description` | required | required |
| `version` | optional, common | preserved verbatim |
| `author` | optional, hermes/anthropic | preserved verbatim |
| `license` | optional, hermes | preserved verbatim |
| `metadata.<vendor>` | optional, hermes/codex/etc. | preserved verbatim |
| Body | Markdown | stored verbatim, treated as opaque |

A skill emitted by anuna-imago loads in [[Claude Code]] and [[hermes-agent]] without modification, provided the body adheres to those runtimes' content conventions (which anuna-imago does not enforce).
