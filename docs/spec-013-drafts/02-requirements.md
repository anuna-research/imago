# Requirements (REQ-### entries)

Functional requirements for the [[SPEC-013-skill-definition-port|skill definition port]]. Each REQ is atomic, verifiable, and traced to at least one [[#TEST-###]] in [[#06-tests]].

---

## REQ-001: Anthropic-compatible on-disk skill format

The system SHALL persist each skill as a directory `<skill-name>/` containing a single file `SKILL.md` whose contents are YAML frontmatter (delimited by `---` lines) followed by a Markdown body, MATCHING the format documented for [[Anthropic Skills]] and used by [[Claude Code]] and [[hermes-agent]] (see [[#01-research-formats]] for the surveyed reference shapes). Frontmatter MUST contain at minimum `name` (string) and `description` (string).

Trace: [[#TEST-001]], [[#TEST-002]], [[#CON-001]]

---

## REQ-002: Agent-driven skill definition

The system SHALL expose a tool `harness-define-skill` callable by the agent through the standard tool-call surface. Given `(:name :description :body :overwrite)` arguments, the tool SHALL write a valid Anthropic-compatible skill to the user-global skills root and return a structured `:ok` plist or a structured rejection plist (never raise an error to the turn loop).

Trace: [[#TEST-003]], [[#TEST-004]], [[#CON-002]]

---

## REQ-003: Discovery at boot

The system SHALL, on harness load, walk every configured skill root in declared resolution order, treat each immediate subdirectory containing a `SKILL.md` as a skill, parse the frontmatter, and register the skill in an in-memory `*skill-registry*`. Skills with unparseable frontmatter SHALL be logged to the receipt log and skipped (not aborted on).

Trace: [[#TEST-005]], [[#TEST-006]], [[#CON-003]]

---

## REQ-004: Listing and inspection

The system SHALL expose tools `harness-list-skills` (returns a list of registered skill names with their `description` first sentence) and `harness-describe-skill` (returns full frontmatter + body for a named skill). Both SHALL be `:read`-permission tools and SHALL never mutate state.

Trace: [[#TEST-007]], [[#CON-004]], [[#CON-005]]

---

## REQ-005: Live install without restart

The system SHALL expose `harness-install-skill` (re-read a single skill from disk into the registry) and `harness-uninstall-skill` (remove from the registry without deleting the file). A successful `harness-define-skill` call SHALL implicitly call `harness-install-skill` so the new skill is available to the same turn that defined it.

Trace: [[#TEST-008]], [[#TEST-009]], [[#CON-006]]

---

## REQ-006: Naming constraints

The system SHALL accept skill names matching `^[a-z][a-z0-9-]*$` (lowercase, alphanumeric and hyphens, starting with a letter) and SHALL reject any other input with a structured `:rejected` plist citing the rule. The skill's directory name on disk SHALL equal the value of the frontmatter `name` field; `harness-define-skill` SHALL refuse to write a skill whose declared name disagrees with its target directory.

Trace: [[#TEST-010]], [[#TEST-011]], [[#CON-002]]

---

## REQ-007: Body validation

The system SHALL verify that the supplied body is valid UTF-8, does not exceed `*skill-max-body-chars*` (default 65536), and does not contain a YAML frontmatter delimiter (`---`) outside the leading-frontmatter section. The Markdown body itself SHALL NOT be parsed for executable content; bodies are treated as opaque guidance text from anuna-imago's perspective.

Trace: [[#TEST-012]], [[#TEST-013]], [[#NFR-003]]

---

## REQ-008: Round-trip preservation of unknown frontmatter fields

The system SHALL preserve frontmatter fields it does not interpret (e.g. `metadata.hermes.tags`, `author`, `license`, vendor-specific blocks) when reading and writing skills. A skill imported from another runtime, defined without modification by the agent, and then exported MUST be byte-identical to the original up to canonical YAML key ordering.

Trace: [[#TEST-014]], [[#TEST-015]]

---

## REQ-009: Persistence semantics

A skill defined via `harness-define-skill` SHALL persist on the file system regardless of whether the operator subsequently calls `save-image!`. The skill SHALL be recovered on next harness boot via [[#REQ-003]]. This is the disk-persistent accumulation contract that complements anuna-imago's existing heap-persistent self-evolution surface.

Trace: [[#TEST-016]], [[#TEST-017]]

---

## REQ-010: Safety surface treatment

The system SHALL NOT execute, evaluate, or compile the body of a skill at load time, install time, or define time. Skill bodies SHALL be treated as opaque text. When an agent acts on the guidance in a skill body, every resulting tool call (including `harness-eval` calls) SHALL pass through the existing safety stack ([[ADR-012-self-mod-adversarial-review|the floor invariants]]). A skill MUST NOT be a vehicle for bypassing `harness-eval`'s pre-filter or reasoner.

Trace: [[#TEST-018]], [[#TEST-019]], [[#TEST-020]], [[#ADR-003]]

---

## REQ-011: Resolution order across roots

When the same skill name exists in multiple configured roots, the system SHALL apply the declared resolution order: project-scoped roots SHALL precede user-global roots, and the first match SHALL win. Subsequent matches SHALL be recorded in `*skill-shadow-log*` so an operator can inspect the shadowed entries.

Trace: [[#TEST-021]], [[#OBS-005]]

---

## REQ-012: Tool-registry namespace separation

The system SHALL register skills in a registry distinct from `*tool-registry*`. A skill name and a tool name SHALL be allowed to coincide without conflict (a skill `foo` and a tool `foo` are independent surfaces). `harness-list-skills` and `harness-list-tools` SHALL be the two ways to enumerate the respective registries.

Trace: [[#TEST-022]], [[#ADR-004]]
